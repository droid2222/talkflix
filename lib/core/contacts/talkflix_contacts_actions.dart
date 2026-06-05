import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';

/// Device contacts flows (invite + save) for Talkflix chat.
///
/// **Backend (optional):** matching address-book phone numbers to Talkflix user
/// IDs is not available in this client repo. If you add something like
/// `POST /me/contacts/match` with `{ "e164": ["+1…"] }` → `{ "matches": [{ "e164", "userId" }] }`,
/// we can wire the picker to open `/app/talk/:userId` when a match exists.
class TalkflixContactsActions {
  TalkflixContactsActions._();

  static bool get supported =>
      AppConfig.deviceContactsEnabled &&
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS);

  static bool _granted(PermissionStatus status) =>
      status == PermissionStatus.granted || status == PermissionStatus.limited;

  static Future<bool> _ensure(BuildContext context, PermissionType type) async {
    if (!supported) {
      _snack(context, 'Contacts are only available on Android and iOS.');
      return false;
    }
    final status = await FlutterContacts.permissions.request(type);
    if (_granted(status)) return true;
    if (!context.mounted) return false;
    if (status == PermissionStatus.permanentlyDenied ||
        status == PermissionStatus.restricted) {
      _snack(
        context,
        'Contacts access is turned off. You can enable it in system settings.',
      );
      return false;
    }
    _snack(context, 'Contacts permission is needed for this action.');
    return false;
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the system contact picker, then the SMS composer with an invite.
  static Future<void> inviteFromNativePicker(BuildContext context) async {
    await sendTextFromNativePicker(
      context: context,
      body: AppConfig.smsInviteBody,
    );
  }

  /// Opens the system contact picker, then the SMS composer with custom text.
  static Future<void> sendTextFromNativePicker({
    required BuildContext context,
    required String body,
  }) async {
    if (!await _ensure(context, PermissionType.read)) return;
    try {
      final id = await FlutterContacts.native.showPicker();
      if (id == null || !context.mounted) return;
      final contact = await FlutterContacts.get(
        id,
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      if (!context.mounted) return;
      if (contact == null) {
        _snack(context, 'Could not read that contact.');
        return;
      }
      final phones = contact.phones
          .map(
            (p) => p.normalizedNumber?.trim().isNotEmpty == true
                ? p.normalizedNumber!.trim()
                : p.number.trim(),
          )
          .where((n) => n.isNotEmpty)
          .toList();
      if (phones.isEmpty) {
        _snack(context, 'That contact has no phone number to text.');
        return;
      }
      final chosen = phones.length == 1
          ? phones.single
          : await _pickPhoneDialog(context, phones);
      if (chosen == null || chosen.isEmpty || !context.mounted) return;
      await _launchSms(context, chosen, body);
    } catch (e) {
      if (context.mounted) {
        _snack(context, 'Could not open contacts. Try again.');
      }
    }
  }

  static Future<String?> _pickPhoneDialog(
    BuildContext context,
    List<String> phones,
  ) {
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Choose number'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: phones
                .map(
                  (p) => ListTile(
                    title: Text(p),
                    onTap: () => Navigator.of(context).pop(p),
                  ),
                )
                .toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _launchSms(
    BuildContext context,
    String rawPhone,
    String body,
  ) async {
    final normalized = _normalizePhoneForSms(rawPhone);
    if (normalized.isEmpty) {
      _snack(context, 'Invalid phone number.');
      return;
    }
    final uri = Uri(
      scheme: 'sms',
      path: normalized,
      queryParameters: <String, String>{'body': body},
    );
    if (!await canLaunchUrl(uri)) {
      if (context.mounted) {
        _snack(context, 'No SMS app is available on this device.');
      }
      return;
    }
    await launchUrl(uri, mode: LaunchMode.platformDefault);
  }

  static String _normalizePhoneForSms(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < trimmed.length; i++) {
      final c = trimmed[i];
      if (c == '+') {
        if (buf.isEmpty) buf.write(c);
        continue;
      }
      if (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) {
        buf.write(c);
      }
    }
    return buf.toString();
  }

  /// Saves the chat partner as a new address-book card (name + Talkflix metadata).
  static Future<void> saveTalkflixConnection({
    required BuildContext context,
    required String displayName,
    required String userId,
    required String username,
  }) async {
    if (userId.isEmpty) {
      _snack(context, 'Missing user id.');
      return;
    }
    if (!await _ensure(context, PermissionType.readWrite)) return;
    final safeName = displayName.trim().isEmpty
        ? 'Talkflix friend'
        : displayName;
    final handle = username.trim().isEmpty ? '' : '@${username.trim()}';
    final noteLines = <String>[
      'Talkflix',
      if (handle.isNotEmpty) 'Username: $handle',
      'User ID: $userId',
      'Open the Talkflix app → Messages to chat or call.',
    ];
    try {
      final contact = Contact(
        name: Name(first: safeName),
        organizations: [
          Organization(
            name: 'Talkflix',
            jobTitle: handle.isEmpty ? null : handle,
            departmentName: 'User ID $userId',
          ),
        ],
        websites: const [Website(url: AppConfig.publicMarketingUrl)],
        // iOS contact notes require an Apple entitlement; keep metadata in org + website.
        notes: Platform.isIOS
            ? const <Note>[]
            : [Note(note: noteLines.join('\n'))],
      );
      await FlutterContacts.create(contact);
      if (context.mounted) {
        _snack(context, 'Saved to your contacts.');
      }
    } catch (_) {
      if (context.mounted) {
        _snack(
          context,
          'Could not save the contact. Check permissions and try again.',
        );
      }
    }
  }
}
