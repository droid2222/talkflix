import 'user_privacy.dart';

class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.username,
    required this.firstLanguage,
    required this.learnLanguage,
    required this.role,
    required this.plan,
    required this.trialUsed,
    required this.meetLanguages,
    required this.city,
    required this.country,
    required this.countryCode,
    this.showCountry = false,
    this.showFlag = false,
    this.showAge = false,
    this.showFollowStats = true,
    this.showOnlineStatus = true,
    this.receiveVoiceCalls = true,
    this.receiveVideoCalls = true,
    required this.nationalityCode,
    required this.nationalityName,
    required this.profilePhotoUrl,
    this.coverPhotoUrls = const [],
    this.coverPhotoThumbUrls = const [],
    this.coverPhotosLocked = false,
    this.relationshipStatus = '',
    this.relationshipStatusVisible = false,
    required this.bioText,
    required this.bioAudioUrl,
    required this.bioAudioDuration,
    this.dateOfBirth = '',
    required this.followersCount,
    required this.followingCount,
    required this.postsCount,
    required this.isFollowing,
    this.age,
    this.gender = '',
    this.canPublishVideo = false,
  });

  final String id;
  final String email;
  final String displayName;
  final String username;
  final String firstLanguage;
  final String learnLanguage;
  final String role;
  final String plan;
  final bool trialUsed;
  final List<String> meetLanguages;
  final String city;
  final String country;
  final String countryCode;
  final bool showCountry;
  final bool showFlag;
  final bool showAge;
  final bool showFollowStats;
  final bool showOnlineStatus;
  final bool receiveVoiceCalls;
  final bool receiveVideoCalls;
  final String nationalityCode;
  final String nationalityName;
  final String profilePhotoUrl;
  final List<String> coverPhotoUrls;
  final List<String> coverPhotoThumbUrls;
  final bool coverPhotosLocked;
  final String relationshipStatus;
  final bool relationshipStatusVisible;
  final String bioText;
  final String bioAudioUrl;
  final int bioAudioDuration;
  final String dateOfBirth;
  final int followersCount;
  final int followingCount;
  final int postsCount;
  final bool isFollowing;
  final int? age;
  final String gender;
  final bool canPublishVideo;

  bool get isProLike => role == 'admin' || plan == 'pro' || plan == 'trial';
  bool get canPublishToTalkiz => canPublishVideo || role == 'creator';

  AppUser copyWith({
    String? id,
    String? email,
    String? displayName,
    String? username,
    String? firstLanguage,
    String? learnLanguage,
    String? role,
    String? plan,
    bool? trialUsed,
    List<String>? meetLanguages,
    String? city,
    String? country,
    String? countryCode,
    bool? showCountry,
    bool? showFlag,
    bool? showAge,
    bool? showFollowStats,
    bool? showOnlineStatus,
    bool? receiveVoiceCalls,
    bool? receiveVideoCalls,
    String? nationalityCode,
    String? nationalityName,
    String? profilePhotoUrl,
    List<String>? coverPhotoUrls,
    List<String>? coverPhotoThumbUrls,
    bool? coverPhotosLocked,
    String? relationshipStatus,
    bool? relationshipStatusVisible,
    String? bioText,
    String? bioAudioUrl,
    int? bioAudioDuration,
    String? dateOfBirth,
    int? followersCount,
    int? followingCount,
    int? postsCount,
    bool? isFollowing,
    int? age,
    String? gender,
    bool? canPublishVideo,
  }) {
    return AppUser(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      username: username ?? this.username,
      firstLanguage: firstLanguage ?? this.firstLanguage,
      learnLanguage: learnLanguage ?? this.learnLanguage,
      role: role ?? this.role,
      plan: plan ?? this.plan,
      trialUsed: trialUsed ?? this.trialUsed,
      meetLanguages: meetLanguages ?? this.meetLanguages,
      city: city ?? this.city,
      country: country ?? this.country,
      countryCode: countryCode ?? this.countryCode,
      showCountry: showCountry ?? this.showCountry,
      showFlag: showFlag ?? this.showFlag,
      showAge: showAge ?? this.showAge,
      showFollowStats: showFollowStats ?? this.showFollowStats,
      showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
      receiveVoiceCalls: receiveVoiceCalls ?? this.receiveVoiceCalls,
      receiveVideoCalls: receiveVideoCalls ?? this.receiveVideoCalls,
      nationalityCode: nationalityCode ?? this.nationalityCode,
      nationalityName: nationalityName ?? this.nationalityName,
      profilePhotoUrl: profilePhotoUrl ?? this.profilePhotoUrl,
      coverPhotoUrls: coverPhotoUrls ?? this.coverPhotoUrls,
      coverPhotoThumbUrls: coverPhotoThumbUrls ?? this.coverPhotoThumbUrls,
      coverPhotosLocked: coverPhotosLocked ?? this.coverPhotosLocked,
      relationshipStatus: relationshipStatus ?? this.relationshipStatus,
      relationshipStatusVisible:
          relationshipStatusVisible ?? this.relationshipStatusVisible,
      bioText: bioText ?? this.bioText,
      bioAudioUrl: bioAudioUrl ?? this.bioAudioUrl,
      bioAudioDuration: bioAudioDuration ?? this.bioAudioDuration,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      postsCount: postsCount ?? this.postsCount,
      isFollowing: isFollowing ?? this.isFollowing,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      canPublishVideo: canPublishVideo ?? this.canPublishVideo,
    );
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? 'User',
      username: json['username']?.toString() ?? 'user',
      firstLanguage: json['firstLanguage']?.toString() ?? '',
      learnLanguage: json['learnLanguage']?.toString() ?? '',
      role: json['role']?.toString() ?? 'user',
      plan: json['plan']?.toString() ?? 'free',
      trialUsed: json['trialUsed'] == true,
      meetLanguages: (json['meetLanguages'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(),
      city: json['city']?.toString() ?? '',
      country: json['country']?.toString() ?? '',
      countryCode: json['countryCode']?.toString() ?? '',
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
      showAge:
          readUserPrivacyPreference(
            json,
            keys: const <String>['showAge', 'ageVisible'],
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
      nationalityCode: json['nationalityCode']?.toString() ?? '',
      nationalityName: json['nationalityName']?.toString() ?? '',
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
      coverPhotoUrls: (json['coverPhotoUrls'] as List<dynamic>? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .take(2)
          .toList(),
      coverPhotoThumbUrls:
          (json['coverPhotoThumbUrls'] as List<dynamic>? ?? const [])
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .take(2)
              .toList(),
      coverPhotosLocked: json['coverPhotosLocked'] == true,
      relationshipStatus: json['relationshipStatus']?.toString().trim() ?? '',
      relationshipStatusVisible: json['relationshipStatusVisible'] == true,
      bioText: json['bioText']?.toString() ?? '',
      bioAudioUrl: json['bioAudioUrl']?.toString() ?? '',
      bioAudioDuration: (json['bioAudioDuration'] as num?)?.toInt() ?? 0,
      dateOfBirth: json['dateOfBirth']?.toString() ?? '',
      followersCount: (json['followersCount'] as num?)?.toInt() ?? 0,
      followingCount: (json['followingCount'] as num?)?.toInt() ?? 0,
      postsCount: (json['postsCount'] as num?)?.toInt() ?? 0,
      isFollowing: json['isFollowing'] == true,
      age: _parseAge(json['age']),
      gender: json['gender']?.toString().trim() ?? '',
      canPublishVideo: json['canPublishVideo'] == true,
    );
  }

  static int? _parseAge(dynamic value) {
    if (value is num) {
      final parsed = value.toInt();
      return parsed > 0 ? parsed : null;
    }
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = int.tryParse(text);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }
}
