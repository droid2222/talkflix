import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_controller.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../content/data/content_repository.dart';
import 'profile_screen.dart' show profileBaseProvider, profileProvider;

String buildProfileQrPayload(String userId) {
  return 'talkflix://app/app/profile/$userId';
}

String? parseProfileQrUserId(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  final uri = Uri.tryParse(trimmed);
  if (uri != null) {
    final pathSegments = uri.pathSegments;
    if (uri.scheme == 'talkflix' && uri.host == 'app') {
      if (pathSegments.length >= 3 &&
          pathSegments[0] == 'app' &&
          pathSegments[1] == 'profile') {
        final userId = pathSegments[2].trim();
        if (userId.isNotEmpty) return userId;
      }
      if (pathSegments.length >= 2 && pathSegments[0] == 'profile') {
        final userId = pathSegments[1].trim();
        if (userId.isNotEmpty) return userId;
      }
    }
    if (pathSegments.length >= 3 &&
        pathSegments[0] == 'app' &&
        pathSegments[1] == 'profile') {
      final userId = pathSegments[2].trim();
      if (userId.isNotEmpty) return userId;
    }
  }

  final match = RegExp(r'^/app/profile/([^/?#]+)$').firstMatch(trimmed);
  if (match != null) {
    final userId = match.group(1)?.trim() ?? '';
    if (userId.isNotEmpty) return userId;
  }
  return null;
}

class ProfileQrScreen extends ConsumerStatefulWidget {
  const ProfileQrScreen({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<ProfileQrScreen> createState() => _ProfileQrScreenState();
}

class _ProfileQrScreenState extends ConsumerState<ProfileQrScreen> {
  final _cardKey = GlobalKey();
  _ProfileQrStyle _style = _ProfileQrStyle.classic;
  bool _saving = false;
  String _profileShareUrl = '';

  bool get _scanSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  bool get _saveSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfileShareLink());
  }

  Future<void> _loadProfileShareLink() async {
    try {
      final share = await ref
          .read(contentRepositoryProvider)
          .createProfileShareLink(widget.userId);
      if (!mounted) return;
      setState(() => _profileShareUrl = share.shareUrl.trim());
    } catch (_) {
      // QR scanning stays available through the direct profile payload.
    }
  }

  Future<void> _shareProfileLink() async {
    final target = _profileShareUrl.trim();
    if (target.isEmpty) {
      _showSnack('Profile share link is not ready yet.');
      return;
    }
    await Share.share(target);
  }

  String _fileSafeName(String value) {
    final cleaned = value.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    return cleaned.isEmpty ? 'profile' : cleaned;
  }

  Future<Uint8List?> _captureCardBytes() async {
    final boundary =
        _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 3);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> _saveQrImage(AppUser user) async {
    if (_saving) return;
    if (!_saveSupported) {
      _showSnack('Saving QR images is not supported on this platform.');
      return;
    }
    setState(() => _saving = true);
    try {
      final granted = await Gal.hasAccess() || await Gal.requestAccess();
      if (!granted) {
        _showSnack('Photo library access is required to save the QR image.');
        return;
      }
      final bytes = await _captureCardBytes();
      if (bytes == null || bytes.isEmpty) {
        _showSnack('Could not prepare the QR image right now.');
        return;
      }
      await Gal.putImageBytes(
        bytes,
        name: 'talkflix_qr_${_fileSafeName(user.username)}',
      );
      _showSnack('QR image saved to your gallery.');
    } catch (_) {
      _showSnack('Could not save the QR image right now.');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final profile = ref.watch(profileProvider(widget.userId));

    return Scaffold(
      backgroundColor: _style.pageBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Profile QR'),
      ),
      body: profile.when(
        data: (user) {
          final qrData = buildProfileQrPayload(user.id);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
            children: [
              Text(
                'Scan to open ${user.displayName} on Talkflix',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Switch the look, save the image, or scan another code.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              RepaintBoundary(
                key: _cardKey,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _style.cardGradient,
                    ),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 28,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          AppAvatar(
                            label: user.displayName,
                            imageUrl: user.profilePhotoUrl,
                            radius: 26,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: _style.onCard,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '@${user.username}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: _style.onCard.withValues(
                                      alpha: 0.82,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: QrImageView(
                          data: qrData,
                          version: QrVersions.auto,
                          size: 248,
                          padding: EdgeInsets.zero,
                          eyeStyle: QrEyeStyle(
                            eyeShape: _style.eyeShape,
                            color: _style.qrColor,
                          ),
                          dataModuleStyle: QrDataModuleStyle(
                            dataModuleShape: _style.dataShape,
                            color: _style.qrColor,
                          ),
                          embeddedImage: const AssetImage(
                            'assets/images/icons/profile_qr_logo.png',
                          ),
                          embeddedImageStyle: const QrEmbeddedImageStyle(
                            size: Size(40, 40),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.qr_code_2_rounded, color: _style.onCard),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Talkflix profile code',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: _style.onCard,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Style',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _ProfileQrStyle.values.map((style) {
                  final selected = style == _style;
                  return ChoiceChip(
                    label: Text(style.label),
                    selected: selected,
                    onSelected: (_) => setState(() => _style = style),
                    selectedColor: style.cardGradient.first.withValues(
                      alpha: 0.2,
                    ),
                    avatar: CircleAvatar(
                      radius: 10,
                      backgroundColor: style.qrColor,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _scanSupported
                          ? () => context.push('/app/profile/qr-scan')
                          : null,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('Scan QR code'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : () => _saveQrImage(user),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.download_rounded),
                      label: Text(_saving ? 'Saving...' : 'Save image'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _profileShareUrl.trim().isEmpty
                    ? null
                    : () => unawaited(_shareProfileLink()),
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('Share profile link'),
              ),
              if (!_scanSupported) ...[
                const SizedBox(height: 12),
                Text(
                  'QR scanning is available on Android, iPhone, Mac, and web builds.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error.toString(), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    ref.invalidate(profileBaseProvider(widget.userId));
                    ref.invalidate(profileProvider(widget.userId));
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProfileQrScannerScreen extends ConsumerStatefulWidget {
  const ProfileQrScannerScreen({super.key});

  @override
  ConsumerState<ProfileQrScannerScreen> createState() =>
      _ProfileQrScannerScreenState();
}

class _ProfileQrScannerScreenState
    extends ConsumerState<ProfileQrScannerScreen> {
  late final MobileScannerController _controller;
  bool _handlingScan = false;

  bool get _supported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_handlingScan) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;

    final userId = parseProfileQrUserId(raw);
    if (userId == null) {
      _handlingScan = true;
      _showSnack('That QR code is not a Talkflix profile code.');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      _handlingScan = false;
      return;
    }

    _handlingScan = true;
    await _controller.stop();
    if (!mounted) return;
    final myUserId = ref.read(sessionControllerProvider).user?.id ?? '';
    if (userId == myUserId) {
      context.go('/app/profile');
      return;
    }
    context.go('/app/profile/$userId');
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan QR code')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'QR scanning is not supported on this platform.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan QR code'),
        actions: [
          IconButton(
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _handleDetection),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.26),
                    Colors.black.withValues(alpha: 0.64),
                  ],
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: talkflixPrimary, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: talkflixPrimary.withValues(alpha: 0.28),
                    blurRadius: 18,
                    spreadRadius: 3,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Point the camera at a Talkflix profile QR code',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'We’ll open the profile as soon as the code is recognized.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.surface,
                      foregroundColor: scheme.onSurface,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Close scanner'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ProfileQrStyle {
  classic(
    label: 'Classic',
    pageBackground: Color(0xFFF7F2EB),
    cardGradient: [Color(0xFFF7EDE2), Color(0xFFFBE7D5)],
    qrColor: Color(0xFF141414),
    onCard: Color(0xFF1C1C1C),
    eyeShape: QrEyeShape.square,
    dataShape: QrDataModuleShape.square,
  ),
  coral(
    label: 'Coral',
    pageBackground: Color(0xFFFFF1EB),
    cardGradient: [Color(0xFFFF845C), Color(0xFFFFB199)],
    qrColor: Color(0xFF7A1A1A),
    onCard: Colors.white,
    eyeShape: QrEyeShape.circle,
    dataShape: QrDataModuleShape.circle,
  ),
  midnight(
    label: 'Midnight',
    pageBackground: Color(0xFF0F1218),
    cardGradient: [Color(0xFF18202C), Color(0xFF0F1722)],
    qrColor: Color(0xFF101828),
    onCard: Colors.white,
    eyeShape: QrEyeShape.square,
    dataShape: QrDataModuleShape.circle,
  );

  const _ProfileQrStyle({
    required this.label,
    required this.pageBackground,
    required this.cardGradient,
    required this.qrColor,
    required this.onCard,
    required this.eyeShape,
    required this.dataShape,
  });

  final String label;
  final Color pageBackground;
  final List<Color> cardGradient;
  final Color qrColor;
  final Color onCard;
  final QrEyeShape eyeShape;
  final QrDataModuleShape dataShape;
}
