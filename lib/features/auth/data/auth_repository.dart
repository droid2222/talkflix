import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/auth/app_user.dart';
import '../../../core/auth/session_identity.dart';
import '../../../core/network/api_client.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref);
});

class AuthResult {
  const AuthResult({
    required this.token,
    required this.sessionId,
    required this.user,
  });

  final String token;
  final String sessionId;
  final AppUser user;
}

class AuthRepository {
  const AuthRepository(this._ref);

  final Ref _ref;

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/auth/login',
      body: {'email': email.trim(), 'password': password},
    );

    final token = data['token']?.toString() ?? '';
    return _authResultFromToken(token);
  }

  Future<AuthResult> startTrial() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson('/billing/start-trial');
    final token = data['token']?.toString() ?? '';
    return _authResultFromToken(token);
  }

  Future<void> forgotPassword(String email) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson(
      '/auth/forgot-password',
      body: {'email': email.trim()},
    );
  }

  Future<void> sendVerificationCode(String email) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson('/auth/send-code', body: {'email': email.trim()});
  }

  Future<String> verifyCode({
    required String email,
    required String code,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/auth/verify-code',
      body: {'email': email.trim(), 'code': code.trim()},
    );
    return data['emailVerificationToken']?.toString() ?? '';
  }

  Future<void> resetPassword({
    required String token,
    required String password,
  }) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson(
      '/auth/reset-password',
      body: {'token': token, 'password': password},
    );
  }

  Future<AppUser> fetchMe({String? tokenOverride}) async {
    final client = ApiClient(
      baseUrl: _ref.read(apiClientProvider).baseUrl,
      token: tokenOverride ?? _ref.read(apiClientProvider).token,
    );
    final data = await client.getJson('/me');
    return AppUser.fromJson(data['user'] as Map<String, dynamic>? ?? {});
  }

  Future<AppUser> saveMeetLanguages(List<String> languages) async {
    final client = _ref.read(apiClientProvider);
    await client.patchJson(
      '/me/meet-languages',
      body: {'languages': languages},
    );
    return fetchMe();
  }

  Future<AuthResult> signup({
    required String email,
    required String password,
    required String displayName,
    required String dob,
    required String gender,
    required String fromCountry,
    required String firstLanguage,
    required String learnLanguage,
    required String emailVerificationToken,
    Uint8List? profilePhotoBytes,
    String? profilePhotoMimeType,
    String? profilePhotoName,
  }) async {
    final baseUrl = _ref
        .read(apiClientProvider)
        .baseUrl
        .replaceAll(RegExp(r'/$'), '');
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/auth/signup'))
          ..fields['email'] = email.trim()
          ..fields['password'] = password
          ..fields['displayName'] = displayName.trim()
          ..fields['dob'] = dob
          ..fields['gender'] = gender
          ..fields['fromCountry'] = fromCountry
          ..fields['firstLanguage'] = firstLanguage
          ..fields['learnLanguage'] = learnLanguage
          ..fields['emailVerificationToken'] = emailVerificationToken;

    if (profilePhotoBytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'profilePhoto',
          profilePhotoBytes,
          filename: profilePhotoName ?? 'profile.jpg',
          contentType: profilePhotoMimeType == null
              ? null
              : _contentTypeFromMime(profilePhotoMimeType),
        ),
      );
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final payload = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(payload['message']?.toString() ?? 'Signup failed');
    }

    final token = payload['token']?.toString() ?? '';
    return _authResultFromToken(token);
  }

  MediaType? _contentTypeFromMime(String mimeType) {
    final parts = mimeType.split('/');
    if (parts.length != 2) return null;
    return MediaType(parts[0], parts[1]);
  }

  Future<AuthResult> _authResultFromToken(String token) async {
    final sessionIdentity = parseSessionIdentityFromToken(token);
    if (!sessionIdentity.isValid) {
      throw Exception('Invalid session token.');
    }
    final user = await fetchMe(tokenOverride: token);
    return AuthResult(
      token: token,
      sessionId: sessionIdentity.sessionId,
      user: user,
    );
  }
}
