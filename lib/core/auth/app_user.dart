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
    required this.nationalityCode,
    required this.nationalityName,
    required this.profilePhotoUrl,
    required this.bioText,
    required this.bioAudioUrl,
    required this.bioAudioDuration,
    required this.followersCount,
    required this.followingCount,
    required this.postsCount,
    required this.isFollowing,
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
  final String nationalityCode;
  final String nationalityName;
  final String profilePhotoUrl;
  final String bioText;
  final String bioAudioUrl;
  final int bioAudioDuration;
  final int followersCount;
  final int followingCount;
  final int postsCount;
  final bool isFollowing;
  final bool canPublishVideo;

  bool get isProLike => role == 'admin' || plan == 'pro' || plan == 'trial';

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
      nationalityCode: json['nationalityCode']?.toString() ?? '',
      nationalityName: json['nationalityName']?.toString() ?? '',
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
      bioText: json['bioText']?.toString() ?? '',
      bioAudioUrl: json['bioAudioUrl']?.toString() ?? '',
      bioAudioDuration: (json['bioAudioDuration'] as num?)?.toInt() ?? 0,
      followersCount: (json['followersCount'] as num?)?.toInt() ?? 0,
      followingCount: (json['followingCount'] as num?)?.toInt() ?? 0,
      postsCount: (json['postsCount'] as num?)?.toInt() ?? 0,
      isFollowing: json['isFollowing'] == true,
      canPublishVideo: json['canPublishVideo'] == true,
    );
  }
}
