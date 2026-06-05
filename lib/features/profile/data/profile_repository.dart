import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../../core/auth/app_user.dart';
import '../../../core/auth/user_privacy.dart';
import '../../../core/network/api_client.dart';

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref);
});

final blockedUsersProvider = FutureProvider.autoDispose<List<BlockedUserEntry>>(
  (ref) async {
    return ref.read(profileRepositoryProvider).fetchBlockedUsers();
  },
);

final profileMediaProvider = FutureProvider.autoDispose
    .family<ProfileMediaPayload, String>((ref, userId) async {
      return ref.read(profileRepositoryProvider).fetchProfileMedia(userId);
    });

class ProfileRepository {
  const ProfileRepository(this._ref);

  final Ref _ref;

  Future<UsernameAvailabilityResult> checkUsernameAvailability(
    String username,
  ) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/me/profile/username-availability',
      queryParameters: <String, String>{'username': username},
    );
    return UsernameAvailabilityResult.fromJson(data);
  }

  Future<void> updateProfile({
    required String displayName,
    required String username,
    required String bioText,
    required String nationalityCode,
    required String firstLanguage,
    required String learnLanguage,
    required List<String> meetLanguages,
    required String relationshipStatus,
    required bool relationshipStatusVisible,
    required String dateOfBirth,
    required String gender,
  }) async {
    final client = _ref.read(apiClientProvider);
    await client.patchJson(
      '/me/profile',
      body: <String, dynamic>{
        'displayName': displayName.trim(),
        'username': username.trim(),
        'bioText': bioText.trim(),
        'nationalityCode': nationalityCode.trim(),
        'firstLanguage': firstLanguage.trim(),
        'learnLanguage': learnLanguage.trim(),
        'meetLanguages': meetLanguages,
        'relationshipStatus': relationshipStatus.trim(),
        'relationshipStatusVisible': relationshipStatusVisible,
        'dateOfBirth': dateOfBirth.trim(),
        'gender': gender.trim(),
      },
    );
  }

  Future<ProfilePrivacyPayload> updatePrivacy({
    bool? showAge,
    bool? showCountry,
    bool? showFlag,
    bool? showFollowStats,
    bool? showOnlineStatus,
    bool? receiveVoiceCalls,
    bool? receiveVideoCalls,
  }) async {
    final client = _ref.read(apiClientProvider);
    final body = <String, dynamic>{};
    if (showAge != null) body['showAge'] = showAge;
    if (showCountry != null) body['showCountry'] = showCountry;
    if (showFlag != null) body['showFlag'] = showFlag;
    if (showFollowStats != null) body['showFollowStats'] = showFollowStats;
    if (showOnlineStatus != null) body['showOnlineStatus'] = showOnlineStatus;
    if (receiveVoiceCalls != null) {
      body['receiveVoiceCalls'] = receiveVoiceCalls;
    }
    if (receiveVideoCalls != null) {
      body['receiveVideoCalls'] = receiveVideoCalls;
    }
    final data = await client.patchJson('/me/privacy', body: body);
    return ProfilePrivacyPayload.fromJson(data);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson(
      '/me/change-password',
      body: <String, dynamic>{
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      },
    );
  }

  Future<void> changeEmail({
    required String newEmail,
    required String password,
  }) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson(
      '/me/change-email',
      body: <String, dynamic>{
        'newEmail': newEmail.trim(),
        'password': password,
      },
    );
  }

  Future<void> deleteAccount({required String password}) async {
    final client = _ref.read(apiClientProvider);
    await client.deleteJson(
      '/me',
      body: <String, dynamic>{'password': password},
      retries: 0,
    );
  }

  Future<ProfilePhotoPayload> uploadProfilePhoto({
    required String imagePath,
  }) async {
    final client = _ref.read(apiClientProvider);
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/me/profile-photo'),
    )..headers['Authorization'] = 'Bearer ${client.token}';
    request.files.add(
      await http.MultipartFile.fromPath(
        'profilePhoto',
        imagePath,
        contentType: _contentTypeForPath(imagePath),
      ),
    );
    final payload = await _sendMultipart(
      request: request,
      fallbackMessage: 'Could not upload profile photo right now.',
    );
    return ProfilePhotoPayload.fromJson(payload);
  }

  Future<ProfilePhotoPayload> removeProfilePhoto() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.deleteJson('/me/profile-photo');
    return ProfilePhotoPayload.fromJson(data);
  }

  Future<ProfileBioAudioPayload> uploadProfileBioAudio({
    required String audioPath,
    required int durationSeconds,
  }) async {
    final client = _ref.read(apiClientProvider);
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/me/profile-bio/audio'),
          )
          ..headers['Authorization'] = 'Bearer ${client.token}'
          ..fields['durationSeconds'] = '$durationSeconds';
    request.files.add(
      await http.MultipartFile.fromPath(
        'audio',
        audioPath,
        contentType: _contentTypeForPath(audioPath),
      ),
    );
    final payload = await _sendMultipart(
      request: request,
      fallbackMessage: 'Could not upload your voice bio right now.',
    );
    return ProfileBioAudioPayload.fromJson(payload);
  }

  Future<ProfileBioAudioPayload> removeProfileBioAudio() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.deleteJson('/me/profile-bio/audio');
    return ProfileBioAudioPayload.fromJson(data);
  }

  Future<AppUser> fetchFreshProfile() async {
    final data = await _ref.read(apiClientProvider).getJson('/me');
    return AppUser.fromJson(data['user'] as Map<String, dynamic>? ?? const {});
  }

  Future<ProfileCoverPayload> uploadCoverPhoto({
    required String imagePath,
    required int slot,
  }) async {
    final client = _ref.read(apiClientProvider);
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/me/cover-photos/upload'),
          )
          ..headers['Authorization'] = 'Bearer ${client.token}'
          ..fields['slot'] = '$slot';
    request.files.add(
      await http.MultipartFile.fromPath(
        'coverPhoto',
        imagePath,
        contentType: _contentTypeForPath(imagePath),
      ),
    );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final payload = _decodePayload(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = _cleanErrorMessage(payload['message']);
      throw Exception(
        message.isNotEmpty
            ? message
            : _multipartErrorMessage(
                response,
                'Could not upload cover photo right now.',
              ),
      );
    }
    return ProfileCoverPayload.fromJson(payload);
  }

  Future<ProfileCoverPayload> removeCoverPhoto({required int slot}) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.deleteJson('/me/cover-photos/$slot');
    return ProfileCoverPayload.fromJson(data);
  }

  Future<ProfileMediaPayload> fetchProfileMedia(String userId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/users/$userId/profile-media');
    return ProfileMediaPayload.fromJson(data);
  }

  Future<ProfileMediaPayload> uploadProfileMediaPhoto({
    required String imagePath,
  }) async {
    final client = _ref.read(apiClientProvider);
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/me/profile-media/photos'),
    )..headers['Authorization'] = 'Bearer ${client.token}';
    request.files.add(
      await http.MultipartFile.fromPath(
        'photo',
        imagePath,
        contentType: _contentTypeForPath(imagePath),
      ),
    );
    final payload = await _sendMultipart(
      request: request,
      fallbackMessage: 'Could not upload profile photo right now.',
    );
    return ProfileMediaPayload.fromJson(payload);
  }

  Future<ProfileMediaPayload> uploadProfileMediaVideo({
    required String videoPath,
    required int durationSeconds,
  }) async {
    final client = _ref.read(apiClientProvider);
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/me/profile-media/video'),
          )
          ..headers['Authorization'] = 'Bearer ${client.token}'
          ..fields['durationSeconds'] = '$durationSeconds';
    request.files.add(
      await http.MultipartFile.fromPath(
        'video',
        videoPath,
        contentType: _videoContentTypeForPath(videoPath),
      ),
    );
    final payload = await _sendMultipart(
      request: request,
      fallbackMessage: 'Could not upload profile video right now.',
    );
    return ProfileMediaPayload.fromJson(payload);
  }

  Future<void> deleteProfileMediaPhoto(String mediaId) async {
    final client = _ref.read(apiClientProvider);
    await client.deleteJson('/me/profile-media/photos/$mediaId');
  }

  Future<void> deleteProfileMediaVideo() async {
    final client = _ref.read(apiClientProvider);
    await client.deleteJson('/me/profile-media/video');
  }

  Future<RelationshipStatusPayload> updateRelationshipStatus({
    required bool visible,
    String? status,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.patchJson(
      '/me/relationship-status',
      body: <String, dynamic>{
        'relationshipStatusVisible': visible,
        ...?status == null
            ? null
            : <String, dynamic>{'relationshipStatus': status},
      },
    );
    return RelationshipStatusPayload.fromJson(data);
  }

  Future<List<BlockedUserEntry>> fetchBlockedUsers() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/me/blocked-users');
    final users = data['users'] as List<dynamic>? ?? const [];
    return users
        .map(
          (item) => BlockedUserEntry.fromJson(
            item as Map<String, dynamic>? ?? const <String, dynamic>{},
          ),
        )
        .toList();
  }

  Future<void> unblockUser(String userId) async {
    final client = _ref.read(apiClientProvider);
    await client.deleteJson('/users/$userId/block');
  }

  Future<Map<String, dynamic>> _sendMultipart({
    required http.MultipartRequest request,
    required String fallbackMessage,
  }) async {
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final payload = _decodePayload(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = _cleanErrorMessage(payload['message']);
      throw Exception(
        message.isNotEmpty
            ? message
            : _multipartErrorMessage(response, fallbackMessage),
      );
    }
    return payload;
  }

  Map<String, dynamic> _decodePayload(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{'message': trimmed};
    } catch (_) {
      return <String, dynamic>{'message': trimmed};
    }
  }

  String _multipartErrorMessage(http.Response response, String fallback) {
    if (response.statusCode == 413) {
      return 'The upload is larger than the server currently allows.';
    }
    if (response.statusCode == 404) {
      return 'The server does not support this upload yet. Please update the API and try again.';
    }
    return fallback;
  }

  String _cleanErrorMessage(Object? raw) {
    final message = raw?.toString().trim() ?? '';
    if (message.isEmpty) return '';
    final lower = message.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      return '';
    }
    return message;
  }

  MediaType? _contentTypeForPath(String path) {
    final lower = path.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    const mimeByExt = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'heif': 'image/heif',
      'bmp': 'image/bmp',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'mp3': 'audio/mpeg',
      'wav': 'audio/wav',
      'ogg': 'audio/ogg',
      'webm': 'audio/webm',
      'mp4': 'audio/mp4',
    };
    final mime = mimeByExt[ext];
    if (mime == null) return null;
    return MediaType.parse(mime);
  }

  MediaType? _videoContentTypeForPath(String path) {
    final lower = path.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    const mimeByExt = <String, String>{
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'm4v': 'video/x-m4v',
      'webm': 'video/webm',
    };
    final mime = mimeByExt[ext];
    if (mime == null) return _contentTypeForPath(path);
    return MediaType.parse(mime);
  }
}

class UsernameAvailabilityResult {
  const UsernameAvailabilityResult({
    required this.username,
    required this.available,
    this.reason = '',
  });

  final String username;
  final bool available;
  final String reason;

  factory UsernameAvailabilityResult.fromJson(Map<String, dynamic> json) {
    return UsernameAvailabilityResult(
      username: json['username']?.toString() ?? '',
      available: json['available'] == true,
      reason: json['reason']?.toString() ?? '',
    );
  }
}

class ProfilePhotoPayload {
  const ProfilePhotoPayload({required this.profilePhotoUrl});

  final String profilePhotoUrl;

  factory ProfilePhotoPayload.fromJson(Map<String, dynamic> json) {
    return ProfilePhotoPayload(
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
    );
  }
}

class ProfileBioAudioPayload {
  const ProfileBioAudioPayload({
    required this.bioAudioUrl,
    required this.bioAudioDuration,
  });

  final String bioAudioUrl;
  final int bioAudioDuration;

  factory ProfileBioAudioPayload.fromJson(Map<String, dynamic> json) {
    return ProfileBioAudioPayload(
      bioAudioUrl: json['bioAudioUrl']?.toString() ?? '',
      bioAudioDuration: (json['bioAudioDuration'] as num?)?.toInt() ?? 0,
    );
  }
}

class ProfileCoverPayload {
  const ProfileCoverPayload({
    required this.coverPhotoUrls,
    required this.coverPhotoThumbUrls,
  });

  final List<String> coverPhotoUrls;
  final List<String> coverPhotoThumbUrls;

  factory ProfileCoverPayload.fromJson(Map<String, dynamic> json) {
    List<String> parseList(String key) {
      return (json[key] as List<dynamic>? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .take(2)
          .toList();
    }

    return ProfileCoverPayload(
      coverPhotoUrls: parseList('coverPhotoUrls'),
      coverPhotoThumbUrls: parseList('coverPhotoThumbUrls'),
    );
  }
}

class ProfileMediaPayload {
  const ProfileMediaPayload({
    required this.photos,
    required this.maxPhotos,
    required this.maxVideos,
    this.video,
  });

  final List<ProfileMediaItem> photos;
  final ProfileMediaItem? video;
  final int maxPhotos;
  final int maxVideos;

  int get remainingPhotoSlots =>
      (maxPhotos - photos.length).clamp(0, maxPhotos).toInt();
  bool get canAddPhoto => remainingPhotoSlots > 0;
  bool get canAddVideo => video == null && maxVideos > 0;

  factory ProfileMediaPayload.fromJson(Map<String, dynamic> json) {
    final container = Map<String, dynamic>.from(
      json['profileMedia'] as Map? ?? json,
    );
    final rawPhotos = container['photos'] as List<dynamic>? ?? const [];
    final rawVideo = container['video'];
    return ProfileMediaPayload(
      photos: rawPhotos
          .whereType<Map>()
          .map(
            (row) => ProfileMediaItem.fromJson(Map<String, dynamic>.from(row)),
          )
          .where((item) => item.url.isNotEmpty)
          .take(4)
          .toList(),
      video: rawVideo is Map
          ? ProfileMediaItem.fromJson(Map<String, dynamic>.from(rawVideo))
          : null,
      maxPhotos: (container['maxPhotos'] as num?)?.toInt() ?? 4,
      maxVideos: (container['maxVideos'] as num?)?.toInt() ?? 1,
    );
  }
}

class ProfileMediaItem {
  const ProfileMediaItem({
    required this.id,
    required this.url,
    required this.thumbnailUrl,
    required this.mimeType,
    required this.durationSeconds,
    required this.order,
  });

  final String id;
  final String url;
  final String thumbnailUrl;
  final String mimeType;
  final int durationSeconds;
  final int order;

  bool get isVideo => mimeType.toLowerCase().startsWith('video/');
  bool get isImage => mimeType.toLowerCase().startsWith('image/');

  factory ProfileMediaItem.fromJson(Map<String, dynamic> json) {
    return ProfileMediaItem(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      thumbnailUrl:
          json['thumbnailUrl']?.toString() ??
          json['thumbUrl']?.toString() ??
          json['posterUrl']?.toString() ??
          '',
      mimeType: json['mimeType']?.toString() ?? '',
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }
}

class RelationshipStatusPayload {
  const RelationshipStatusPayload({
    required this.relationshipStatus,
    required this.relationshipStatusVisible,
  });

  final String relationshipStatus;
  final bool relationshipStatusVisible;

  factory RelationshipStatusPayload.fromJson(Map<String, dynamic> json) {
    return RelationshipStatusPayload(
      relationshipStatus: json['relationshipStatus']?.toString().trim() ?? '',
      relationshipStatusVisible: json['relationshipStatusVisible'] == true,
    );
  }
}

class ProfilePrivacyPayload {
  const ProfilePrivacyPayload({
    required this.showAge,
    required this.showCountry,
    required this.showFlag,
    required this.showFollowStats,
    required this.showOnlineStatus,
    required this.receiveVoiceCalls,
    required this.receiveVideoCalls,
  });

  final bool showAge;
  final bool showCountry;
  final bool showFlag;
  final bool showFollowStats;
  final bool showOnlineStatus;
  final bool receiveVoiceCalls;
  final bool receiveVideoCalls;

  factory ProfilePrivacyPayload.fromJson(Map<String, dynamic> json) {
    return ProfilePrivacyPayload(
      showAge:
          readUserPrivacyPreference(
            json,
            keys: const <String>['showAge', 'ageVisible'],
          ) ==
          true,
      showCountry:
          readUserPrivacyPreference(
            json,
            keys: const <String>['showCountry', 'countryVisible'],
          ) ==
          true,
      showFlag:
          readUserPrivacyPreference(
            json,
            keys: const <String>[
              'showFlag',
              'flagVisible',
              'showNationalityFlag',
            ],
          ) ==
          true,
      showFollowStats:
          readUserPrivacyPreference(
            json,
            keys: const <String>[
              'showFollowStats',
              'followStatsVisible',
              'followersVisible',
            ],
          ) ??
          true,
      showOnlineStatus:
          readUserPrivacyPreference(
            json,
            keys: const <String>['showOnlineStatus', 'onlineStatusVisible'],
          ) ??
          true,
      receiveVoiceCalls:
          readUserPrivacyPreference(
            json,
            keys: const <String>[
              'receiveVoiceCalls',
              'allowVoiceCalls',
              'voiceCallsEnabled',
            ],
          ) ??
          true,
      receiveVideoCalls:
          readUserPrivacyPreference(
            json,
            keys: const <String>[
              'receiveVideoCalls',
              'allowVideoCalls',
              'videoCallsEnabled',
            ],
          ) ??
          true,
    );
  }
}

class BlockedUserEntry {
  const BlockedUserEntry({
    required this.id,
    required this.displayName,
    required this.username,
    required this.profilePhotoUrl,
    required this.blockedAt,
  });

  final String id;
  final String displayName;
  final String username;
  final String profilePhotoUrl;
  final int blockedAt;

  factory BlockedUserEntry.fromJson(Map<String, dynamic> json) {
    return BlockedUserEntry(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString().trim().isNotEmpty == true
          ? json['displayName'].toString().trim()
          : 'User',
      username: json['username']?.toString() ?? '',
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
      blockedAt: (json['blockedAt'] as num?)?.toInt() ?? 0,
    );
  }
}
