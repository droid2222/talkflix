import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';

final contentRepositoryProvider = Provider<ContentRepository>((ref) {
  return ContentRepository(ref);
});

final publishedVideosProvider = FutureProvider<List<ContentVideoItem>>((
  ref,
) async {
  return ref.read(contentRepositoryProvider).fetchPublishedVideos();
});

final podcastEpisodesProvider =
    FutureProvider<ContentFeedPage<PodcastEpisodeItem>>((ref) async {
      return ref.read(contentRepositoryProvider).fetchPodcastEpisodes();
    });

class ContentFeedPage<T> {
  const ContentFeedPage({
    required this.items,
    required this.hasMore,
    this.nextCursor,
  });

  final List<T> items;
  final bool hasMore;
  final String? nextCursor;
}

class ContentVideoItem {
  const ContentVideoItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.sourceLocale,
    required this.videoUrl,
    required this.posterUrl,
    required this.publishedAt,
  });

  final String id;
  final String title;
  final String summary;
  final String sourceLocale;
  final String videoUrl;
  final String posterUrl;
  final DateTime? publishedAt;

  factory ContentVideoItem.fromListJson(Map<String, dynamic> json) {
    return ContentVideoItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      sourceLocale: json['sourceLocale']?.toString() ?? 'und',
      videoUrl: json['videoUrl']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString() ?? '',
      publishedAt: _parseDate(json['publishedAt']),
    );
  }

  static DateTime? _parseDate(dynamic raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toLocal();
  }
}

class ContentTranscriptSegment {
  const ContentTranscriptSegment({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int index;
  final int startMs;
  final int endMs;
  final String text;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'index': index,
      'startMs': startMs,
      'endMs': endMs,
      'text': text,
    };
  }

  factory ContentTranscriptSegment.fromJson(Map<String, dynamic> json) {
    return ContentTranscriptSegment(
      index: (json['index'] as num?)?.toInt() ?? 0,
      startMs: (json['startMs'] as num?)?.toInt() ?? 0,
      endMs: (json['endMs'] as num?)?.toInt() ?? 0,
      text: json['text']?.toString() ?? '',
    );
  }
}

class ContentTranscriptTrack {
  const ContentTranscriptTrack({
    required this.id,
    required this.contentId,
    required this.kind,
    required this.languageCode,
    required this.sourceLanguageCode,
    required this.status,
    required this.segmentCount,
    required this.createdAt,
    required this.updatedAt,
    required this.segments,
  });

  final String id;
  final String contentId;
  final String kind;
  final String languageCode;
  final String sourceLanguageCode;
  final String status;
  final int segmentCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<ContentTranscriptSegment> segments;

  bool get isSource => kind == 'source';

  factory ContentTranscriptTrack.fromJson(Map<String, dynamic> json) {
    final segments = (json['segments'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) =>
              ContentTranscriptSegment.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
    return ContentTranscriptTrack(
      id: json['id']?.toString() ?? '',
      contentId: json['contentId']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'source',
      languageCode: json['languageCode']?.toString() ?? 'und',
      sourceLanguageCode: json['sourceLanguageCode']?.toString() ?? 'und',
      status: json['status']?.toString() ?? 'ready',
      segmentCount: (json['segmentCount'] as num?)?.toInt() ?? segments.length,
      createdAt: ContentVideoItem._parseDate(json['createdAt']),
      updatedAt: ContentVideoItem._parseDate(json['updatedAt']),
      segments: segments,
    );
  }
}

class ContentTranscriptGenerationRequest {
  const ContentTranscriptGenerationRequest({required this.status, this.track});

  final String status;
  final ContentTranscriptTrack? track;

  bool get isReady => status == 'ready' && track != null;
  bool get isProcessing => status == 'pending' || status == 'processing';

  factory ContentTranscriptGenerationRequest.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawStatus =
        json['status']?.toString() ??
        (json['job'] as Map?)?['status']?.toString() ??
        ((json['track'] as Map?) == null ? 'pending' : 'ready');
    final trackMap = json['track'] as Map?;
    return ContentTranscriptGenerationRequest(
      status: rawStatus,
      track: trackMap == null
          ? null
          : ContentTranscriptTrack.fromJson(
              Map<String, dynamic>.from(trackMap),
            ),
    );
  }
}

class ContentShareLink {
  const ContentShareLink({
    required this.token,
    required this.shareUrl,
    required this.webPreviewUrl,
    required this.appShareUrl,
    required this.nativeAppUrl,
    required this.previewSeconds,
    required this.shareKind,
    required this.contentId,
    required this.entityType,
    required this.entityId,
    required this.canonicalRoute,
    this.expiresAt,
  });

  final String token;
  final String shareUrl;
  final String webPreviewUrl;
  final String appShareUrl;
  final String nativeAppUrl;
  final int previewSeconds;
  final String shareKind;
  final String contentId;
  final String entityType;
  final String entityId;
  final String canonicalRoute;
  final DateTime? expiresAt;

  factory ContentShareLink.fromJson(Map<String, dynamic> json) {
    final contentId = json['contentId']?.toString() ?? '';
    final entityId = json['entityId']?.toString() ?? contentId;
    return ContentShareLink(
      token: json['token']?.toString() ?? '',
      shareUrl: json['shareUrl']?.toString() ?? '',
      webPreviewUrl: json['webPreviewUrl']?.toString() ?? '',
      appShareUrl: json['appShareUrl']?.toString() ?? '',
      nativeAppUrl: json['nativeAppUrl']?.toString() ?? '',
      previewSeconds: (json['previewSeconds'] as num?)?.toInt() ?? 0,
      shareKind: json['shareKind']?.toString() ?? 'post',
      contentId: contentId,
      entityType: json['entityType']?.toString() ?? 'content',
      entityId: entityId,
      canonicalRoute: json['canonicalRoute']?.toString() ?? '',
      expiresAt: ContentVideoItem._parseDate(json['expiresAt']),
    );
  }
}

class SharedLinkResolution {
  const SharedLinkResolution({
    required this.mode,
    required this.entityType,
    required this.entityId,
    required this.shareKind,
    required this.contentId,
    required this.canonicalRoute,
    required this.shareUrl,
    required this.webPreviewUrl,
    required this.appShareUrl,
    required this.nativeAppUrl,
  });

  final String mode;
  final String entityType;
  final String entityId;
  final String shareKind;
  final String contentId;
  final String canonicalRoute;
  final String shareUrl;
  final String webPreviewUrl;
  final String appShareUrl;
  final String nativeAppUrl;

  bool get isFullAccess => mode == 'full_access';

  factory SharedLinkResolution.fromJson(Map<String, dynamic> json) {
    final contentId = json['contentId']?.toString() ?? '';
    final entityId = json['entityId']?.toString() ?? contentId;
    return SharedLinkResolution(
      mode: json['mode']?.toString() ?? 'preview_only',
      entityType: json['entityType']?.toString() ?? 'content',
      entityId: entityId,
      shareKind: json['shareKind']?.toString() ?? 'post',
      contentId: contentId,
      canonicalRoute: json['canonicalRoute']?.toString() ?? '',
      shareUrl: json['shareUrl']?.toString() ?? '',
      webPreviewUrl: json['webPreviewUrl']?.toString() ?? '',
      appShareUrl: json['appShareUrl']?.toString() ?? '',
      nativeAppUrl: json['nativeAppUrl']?.toString() ?? '',
    );
  }
}

class SharedLinkResolveResult {
  const SharedLinkResolveResult({required this.resolution, this.item});

  final SharedLinkResolution resolution;
  final PublicSharedContentItem? item;

  factory SharedLinkResolveResult.fromJson(Map<String, dynamic> json) {
    return SharedLinkResolveResult(
      resolution: SharedLinkResolution.fromJson(
        Map<String, dynamic>.from(json['resolution'] as Map? ?? const {}),
      ),
      item: json['item'] is Map
          ? PublicSharedContentItem.fromJson(
              Map<String, dynamic>.from(json['item'] as Map),
            )
          : null,
    );
  }
}

class PublicSharedContentAsset {
  const PublicSharedContentAsset({
    required this.role,
    required this.order,
    required this.url,
    required this.previewUrl,
    required this.posterUrl,
    required this.mimeType,
    required this.lockedAfterSeconds,
  });

  final String role;
  final int order;
  final String url;
  final String previewUrl;
  final String posterUrl;
  final String mimeType;
  final int lockedAfterSeconds;

  bool get isVideo => mimeType.toLowerCase().startsWith('video/');
  bool get isImage => mimeType.toLowerCase().startsWith('image/');

  factory PublicSharedContentAsset.fromJson(Map<String, dynamic> json) {
    return PublicSharedContentAsset(
      role: json['role']?.toString() ?? 'gallery_item',
      order: (json['order'] as num?)?.toInt() ?? 0,
      url: json['url']?.toString() ?? '',
      previewUrl: json['previewUrl']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? '',
      lockedAfterSeconds: (json['lockedAfterSeconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class PublicSharedContentItem {
  const PublicSharedContentItem({
    required this.shareToken,
    required this.entityType,
    required this.entityId,
    required this.shareKind,
    required this.contentId,
    required this.contentKind,
    required this.title,
    required this.summary,
    required this.body,
    required this.sourceLocale,
    required this.authorName,
    required this.authorUsername,
    required this.authorProfilePhotoUrl,
    required this.likeCount,
    required this.commentCount,
    required this.viewCount,
    required this.createdAt,
    required this.publishedAt,
    required this.previewSeconds,
    required this.shareUrl,
    required this.webPreviewUrl,
    required this.appShareUrl,
    required this.canonicalPath,
    required this.requiresAppForFull,
    required this.videoUrl,
    required this.previewUrl,
    required this.posterUrl,
    required this.mimeType,
    required this.byteSize,
    required this.coverUrl,
    required this.audioUrl,
    required this.audioMimeType,
    required this.transcript,
    required this.assets,
    required this.mediaUrl,
    required this.mediaMimeType,
    required this.profileId,
    required this.profileName,
    required this.profileUsername,
    required this.profilePhotoUrl,
    required this.broadcastId,
    required this.roomType,
    required this.hostName,
    required this.hostProfilePhotoUrl,
    required this.isPrivate,
    required this.expiresAt,
  });

  final String shareToken;
  final String entityType;
  final String entityId;
  final String shareKind;
  final String contentId;
  final String contentKind;
  final String title;
  final String summary;
  final String body;
  final String sourceLocale;
  final String authorName;
  final String authorUsername;
  final String authorProfilePhotoUrl;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final DateTime? createdAt;
  final DateTime? publishedAt;
  final int previewSeconds;
  final String shareUrl;
  final String webPreviewUrl;
  final String appShareUrl;
  final String canonicalPath;
  final bool requiresAppForFull;
  final String videoUrl;
  final String previewUrl;
  final String posterUrl;
  final String mimeType;
  final int byteSize;
  final String coverUrl;
  final String audioUrl;
  final String audioMimeType;
  final ContentTranscriptTrack? transcript;
  final List<PublicSharedContentAsset> assets;
  final String mediaUrl;
  final String mediaMimeType;
  final String profileId;
  final String profileName;
  final String profileUsername;
  final String profilePhotoUrl;
  final String broadcastId;
  final String roomType;
  final String hostName;
  final String hostProfilePhotoUrl;
  final bool isPrivate;
  final DateTime? expiresAt;

  bool get isVideo => shareKind == 'video';
  bool get isPodcast => shareKind == 'podcast';
  bool get isPost => shareKind == 'post';
  bool get isLive => shareKind == 'live' || entityType == 'live';
  bool get isProfile => shareKind == 'profile' || entityType == 'profile';

  factory PublicSharedContentItem.fromJson(Map<String, dynamic> json) {
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) =>
              PublicSharedContentAsset.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
    return PublicSharedContentItem(
      shareToken: json['shareToken']?.toString() ?? '',
      entityType: json['entityType']?.toString() ?? 'content',
      entityId:
          json['entityId']?.toString() ?? json['contentId']?.toString() ?? '',
      shareKind: json['shareKind']?.toString() ?? 'post',
      contentId: json['contentId']?.toString() ?? '',
      contentKind: json['contentKind']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      sourceLocale: json['sourceLocale']?.toString() ?? 'und',
      authorName: json['authorName']?.toString() ?? 'User',
      authorUsername: json['authorUsername']?.toString() ?? '',
      authorProfilePhotoUrl: json['authorProfilePhotoUrl']?.toString() ?? '',
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
      viewCount: (json['viewCount'] as num?)?.toInt() ?? 0,
      createdAt: ContentVideoItem._parseDate(json['createdAt']),
      publishedAt: ContentVideoItem._parseDate(json['publishedAt']),
      previewSeconds: (json['previewSeconds'] as num?)?.toInt() ?? 0,
      shareUrl: json['shareUrl']?.toString() ?? '',
      webPreviewUrl: json['webPreviewUrl']?.toString() ?? '',
      appShareUrl: json['appShareUrl']?.toString() ?? '',
      canonicalPath: json['canonicalPath']?.toString() ?? '',
      requiresAppForFull: json['requiresAppForFull'] == true,
      videoUrl: json['videoUrl']?.toString() ?? '',
      previewUrl: json['previewUrl']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? '',
      byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
      coverUrl: json['coverUrl']?.toString() ?? '',
      audioUrl: json['audioUrl']?.toString() ?? '',
      audioMimeType: json['audioMimeType']?.toString() ?? '',
      transcript: json['transcript'] is Map
          ? ContentTranscriptTrack.fromJson(
              Map<String, dynamic>.from(json['transcript'] as Map),
            )
          : null,
      assets: assets,
      mediaUrl: json['mediaUrl']?.toString() ?? '',
      mediaMimeType: json['mediaMimeType']?.toString() ?? '',
      profileId: json['profileId']?.toString() ?? '',
      profileName: json['profileName']?.toString() ?? '',
      profileUsername: json['profileUsername']?.toString() ?? '',
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
      broadcastId: json['broadcastId']?.toString() ?? '',
      roomType: json['roomType']?.toString() ?? '',
      hostName: json['hostName']?.toString() ?? '',
      hostProfilePhotoUrl: json['hostProfilePhotoUrl']?.toString() ?? '',
      isPrivate: json['isPrivate'] == true,
      expiresAt: ContentVideoItem._parseDate(json['expiresAt']),
    );
  }
}

class ContentVideoDetail {
  const ContentVideoDetail({
    required this.id,
    required this.userId,
    required this.authorName,
    required this.title,
    required this.summary,
    required this.body,
    required this.sourceLocale,
    required this.status,
    required this.videoUrl,
    required this.posterUrl,
    required this.mimeType,
    required this.byteSize,
    required this.likeCount,
    required this.commentCount,
    required this.viewCount,
    required this.likedByMe,
    required this.savedByMe,
    required this.createdAt,
    required this.publishedAt,
    required this.transcriptStatus,
    required this.transcriptErrorMessage,
    required this.transcripts,
  });

  final String id;
  final String userId;
  final String authorName;
  final String title;
  final String summary;
  final String body;
  final String sourceLocale;
  final String status;
  final String videoUrl;
  final String posterUrl;
  final String mimeType;
  final int byteSize;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final bool likedByMe;
  final bool savedByMe;
  final DateTime? createdAt;
  final DateTime? publishedAt;
  final String transcriptStatus;
  final String transcriptErrorMessage;
  final List<ContentTranscriptTrack> transcripts;

  factory ContentVideoDetail.fromJson(Map<String, dynamic> json) {
    final transcripts = (json['transcripts'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) =>
              ContentTranscriptTrack.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
    return ContentVideoDetail(
      id: json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      authorName: json['authorName']?.toString() ?? 'User',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      sourceLocale: json['sourceLocale']?.toString() ?? 'und',
      status: json['status']?.toString() ?? 'published',
      videoUrl: json['videoUrl']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? '',
      byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
      viewCount: (json['viewCount'] as num?)?.toInt() ?? 0,
      likedByMe: json['likedByMe'] == true,
      savedByMe: json['savedByMe'] == true,
      createdAt: ContentVideoItem._parseDate(json['createdAt']),
      publishedAt: ContentVideoItem._parseDate(json['publishedAt']),
      transcriptStatus: json['transcriptStatus']?.toString() ?? 'none',
      transcriptErrorMessage: json['transcriptErrorMessage']?.toString() ?? '',
      transcripts: transcripts,
    );
  }
}

class UserPostItem {
  const UserPostItem({
    required this.id,
    required this.userId,
    required this.kind,
    required this.authorName,
    required this.authorUsername,
    required this.authorProfilePhotoUrl,
    required this.title,
    required this.summary,
    required this.body,
    required this.assets,
    required this.mediaUrl,
    required this.mediaMimeType,
    required this.likeCount,
    required this.commentCount,
    required this.viewCount,
    required this.likedByMe,
    required this.savedByMe,
    required this.publishedAt,
  });

  final String id;
  final String userId;
  final String kind;
  final String authorName;
  final String authorUsername;
  final String authorProfilePhotoUrl;
  final String title;
  final String summary;
  final String body;
  final List<ContentAssetItem> assets;
  final String mediaUrl;
  final String mediaMimeType;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final bool likedByMe;
  final bool savedByMe;
  final DateTime? publishedAt;

  factory UserPostItem.fromJson(Map<String, dynamic> json) {
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => ContentAssetItem.fromJson(Map<String, dynamic>.from(row)))
        .toList();
    final fallbackMediaUrl = json['mediaUrl']?.toString() ?? '';
    final fallbackMimeType = json['mediaMimeType']?.toString() ?? '';
    return UserPostItem(
      id: json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'text',
      authorName: json['authorName']?.toString() ?? 'User',
      authorUsername: json['authorUsername']?.toString() ?? '',
      authorProfilePhotoUrl: json['authorProfilePhotoUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      assets: assets,
      mediaUrl: assets.isNotEmpty ? assets.first.url : fallbackMediaUrl,
      mediaMimeType: assets.isNotEmpty
          ? assets.first.mimeType
          : fallbackMimeType,
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
      viewCount: (json['viewCount'] as num?)?.toInt() ?? 0,
      likedByMe: json['likedByMe'] == true,
      savedByMe: json['savedByMe'] == true,
      publishedAt: ContentVideoItem._parseDate(json['publishedAt']),
    );
  }
}

class ContentAssetItem {
  const ContentAssetItem({
    required this.role,
    required this.url,
    required this.posterUrl,
    required this.mimeType,
    required this.order,
  });

  final String role;
  final String url;
  final String posterUrl;
  final String mimeType;
  final int order;

  bool get isVideo => mimeType.toLowerCase().startsWith('video/');
  bool get isImage => mimeType.toLowerCase().startsWith('image/');
  bool get isAudio => mimeType.toLowerCase().startsWith('audio/');

  factory ContentAssetItem.fromJson(Map<String, dynamic> json) {
    return ContentAssetItem(
      role: json['role']?.toString() ?? 'gallery_item',
      url: json['url']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? '',
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }
}

class PodcastEpisodeItem {
  const PodcastEpisodeItem({
    required this.id,
    required this.userId,
    required this.authorName,
    required this.authorUsername,
    required this.authorProfilePhotoUrl,
    required this.title,
    required this.summary,
    required this.body,
    required this.coverUrl,
    required this.audioUrl,
    required this.audioMimeType,
    required this.transcriptStatus,
    required this.transcriptErrorMessage,
    required this.transcripts,
    required this.likeCount,
    required this.commentCount,
    required this.viewCount,
    required this.likedByMe,
    required this.savedByMe,
    required this.publishedAt,
  });

  final String id;
  final String userId;
  final String authorName;
  final String authorUsername;
  final String authorProfilePhotoUrl;
  final String title;
  final String summary;
  final String body;
  final String coverUrl;
  final String audioUrl;
  final String audioMimeType;
  final String transcriptStatus;
  final String transcriptErrorMessage;
  final List<ContentTranscriptTrack> transcripts;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final bool likedByMe;
  final bool savedByMe;
  final DateTime? publishedAt;

  factory PodcastEpisodeItem.fromJson(Map<String, dynamic> json) {
    return PodcastEpisodeItem(
      id: json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      authorName: json['authorName']?.toString() ?? 'User',
      authorUsername: json['authorUsername']?.toString() ?? '',
      authorProfilePhotoUrl: json['authorProfilePhotoUrl']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString() ?? '',
      audioUrl: json['audioUrl']?.toString() ?? '',
      audioMimeType: json['audioMimeType']?.toString() ?? '',
      transcriptStatus: json['transcriptStatus']?.toString() ?? 'none',
      transcriptErrorMessage: json['transcriptErrorMessage']?.toString() ?? '',
      transcripts: (json['transcripts'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (row) =>
                ContentTranscriptTrack.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList(),
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
      viewCount: (json['viewCount'] as num?)?.toInt() ?? 0,
      likedByMe: json['likedByMe'] == true,
      savedByMe: json['savedByMe'] == true,
      publishedAt: ContentVideoItem._parseDate(json['publishedAt']),
    );
  }
}

class ContentCommentItem {
  const ContentCommentItem({
    required this.id,
    required this.userId,
    required this.authorName,
    required this.body,
    required this.createdAt,
    required this.likeCount,
    required this.likedByMe,
    this.parentId,
    this.replyToName,
  });

  final String id;
  final String userId;
  final String authorName;
  final String body;
  final DateTime? createdAt;
  final int likeCount;
  final bool likedByMe;
  final String? parentId;
  final String? replyToName;

  bool get isReply => parentId != null;

  factory ContentCommentItem.fromJson(Map<String, dynamic> json) {
    return ContentCommentItem(
      id: json['id']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      authorName: json['authorName']?.toString() ?? 'User',
      body: json['body']?.toString() ?? '',
      createdAt: ContentVideoItem._parseDate(json['createdAt']),
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      likedByMe: json['likedByMe'] == true,
      parentId: json['parentId']?.toString(),
      replyToName: json['replyToName']?.toString(),
    );
  }
}

class ContentLikeState {
  const ContentLikeState({required this.likeCount, required this.likedByMe});

  final int likeCount;
  final bool likedByMe;
}

class ContentViewState {
  const ContentViewState({required this.viewCount});

  final int viewCount;
}

class AddedContentComment {
  const AddedContentComment({
    required this.comment,
    required this.commentCount,
  });

  final ContentCommentItem comment;
  final int commentCount;
}

/// Drives the shell to hide the bottom nav while the comments sheet is open.
final contentCommentsActiveProvider = StateProvider<bool>((ref) => false);

final userPostsProvider = FutureProvider<ContentFeedPage<UserPostItem>>((
  ref,
) async {
  return ref.read(contentRepositoryProvider).fetchUserPosts();
});

/// Fetches posts for any user by their ID.
/// This is separate from the global content feed and is used by profile pages.
final userPostsByIdProvider = FutureProvider.family<List<UserPostItem>, String>(
  (ref, userId) async {
    return ref.read(contentRepositoryProvider).fetchPostsByUserId(userId);
  },
);

class CreatedVideoDraft {
  const CreatedVideoDraft({required this.id, required this.status});

  final String id;
  final String status;
}

class ContentRepository {
  const ContentRepository(this._ref);

  final Ref _ref;

  ContentFeedPage<T> _parseFeedPage<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    final items = (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => fromJson(Map<String, dynamic>.from(row)))
        .toList();
    final pageInfo = Map<String, dynamic>.from(
      data['pageInfo'] as Map? ?? const {},
    );
    return ContentFeedPage<T>(
      items: items,
      hasMore: pageInfo['hasMore'] == true,
      nextCursor: pageInfo['nextCursor']?.toString(),
    );
  }

  String _multipartErrorMessage(http.Response response, String fallback) {
    if (response.body.isNotEmpty) {
      try {
        final payload = jsonDecode(response.body);
        if (payload is Map<String, dynamic>) {
          final message = payload['message']?.toString().trim() ?? '';
          if (message.isNotEmpty) return message;
        }
      } catch (_) {
        // Fall through to status-based fallback when a proxy/server returns HTML.
      }
    }
    if (response.statusCode == 413) {
      return 'The upload is larger than the server currently allows.';
    }
    return fallback;
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
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'm4v': 'video/x-m4v',
      'avi': 'video/x-msvideo',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'mp3': 'audio/mpeg',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'wav': 'audio/wav',
      'ogg': 'audio/ogg',
      'flac': 'audio/flac',
    };
    final mime = mimeByExt[ext];
    if (mime == null) return null;
    return MediaType.parse(mime);
  }

  Future<List<ContentVideoItem>> fetchPublishedVideos() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/content/videos');
    final items = (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) =>
              ContentVideoItem.fromListJson(Map<String, dynamic>.from(row)),
        )
        .toList();
    return items;
  }

  Future<ContentFeedPage<UserPostItem>> fetchUserPosts({
    String? cursor,
    int limit = 20,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/content/posts',
      queryParameters: <String, String>{
        'limit': '$limit',
        if ((cursor ?? '').trim().isNotEmpty) 'cursor': cursor!.trim(),
      },
    );
    return _parseFeedPage<UserPostItem>(data, UserPostItem.fromJson);
  }

  Future<List<UserPostItem>> fetchPostsByUserId(String userId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/users/$userId/posts',
      queryParameters: const {'limit': '100'},
    );
    return _parseFeedPage<UserPostItem>(data, UserPostItem.fromJson).items;
  }

  Future<List<PodcastEpisodeItem>> fetchPodcastsByUserId(String userId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/users/$userId/podcasts',
      queryParameters: const {'limit': '100'},
    );
    return _parseFeedPage<PodcastEpisodeItem>(
      data,
      PodcastEpisodeItem.fromJson,
    ).items;
  }

  Future<ContentFeedPage<PodcastEpisodeItem>> fetchPodcastEpisodes({
    String? cursor,
    int limit = 20,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/content/podcasts',
      queryParameters: <String, String>{
        'limit': '$limit',
        if ((cursor ?? '').trim().isNotEmpty) 'cursor': cursor!.trim(),
      },
    );
    return _parseFeedPage<PodcastEpisodeItem>(
      data,
      PodcastEpisodeItem.fromJson,
    );
  }

  Future<Set<String>> fetchSavedContentIds({int limit = 300}) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/me/content/saved-ids',
      queryParameters: {'limit': '$limit'},
    );
    return (data['ids'] as List<dynamic>? ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  Future<void> saveContent(String contentId) async {
    await _ref
        .read(apiClientProvider)
        .postJson('/content/items/$contentId/save');
  }

  Future<void> unsaveContent(String contentId) async {
    await _ref
        .read(apiClientProvider)
        .deleteJson('/content/items/$contentId/save');
  }

  Future<ContentShareLink> createContentShareLink(String contentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson('/content/items/$contentId/share-link');
    return ContentShareLink.fromJson(
      Map<String, dynamic>.from(data['share'] as Map? ?? const {}),
    );
  }

  Future<PublicSharedContentItem> fetchPublicSharePreview(String token) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/share/$token');
    return PublicSharedContentItem.fromJson(
      Map<String, dynamic>.from(data['item'] as Map? ?? const {}),
    );
  }

  Future<SharedLinkResolveResult> resolveShareLink(String token) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/share/$token/resolve');
    return SharedLinkResolveResult.fromJson(data);
  }

  Future<ContentShareLink> createLiveShareLink({
    required String broadcastId,
    required Map<String, dynamic> room,
  }) async {
    final data = await _ref
        .read(apiClientProvider)
        .postJson('/share/live/$broadcastId', body: room);
    return ContentShareLink.fromJson(
      Map<String, dynamic>.from(data['share'] as Map? ?? const {}),
    );
  }

  Future<ContentShareLink> createProfileShareLink(String userId) async {
    final data = await _ref
        .read(apiClientProvider)
        .postJson('/share/profile/$userId');
    return ContentShareLink.fromJson(
      Map<String, dynamic>.from(data['share'] as Map? ?? const {}),
    );
  }

  Future<CreatedVideoDraft> createVideoDraft({
    required String title,
    String? summary,
    String sourceLocale = 'und',
    List<String> translationTargets = const [],
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/videos',
      body: <String, dynamic>{
        'title': title.trim(),
        'summary': (summary ?? '').trim(),
        'sourceLocale': sourceLocale.trim(),
        'translationTargets': translationTargets,
      },
    );
    final content = data['content'] as Map<String, dynamic>? ?? const {};
    return CreatedVideoDraft(
      id: content['id']?.toString() ?? '',
      status: content['status']?.toString() ?? 'draft',
    );
  }

  Future<void> uploadVideoFile({
    required String contentId,
    required XFile videoFile,
  }) async {
    final client = _ref.read(apiClientProvider);
    final token = client.token ?? '';
    if (token.isEmpty) {
      throw Exception('Not authenticated');
    }
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/content/videos/$contentId/upload'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(
      await http.MultipartFile.fromPath(
        'video',
        videoFile.path,
        filename: videoFile.name,
        contentType: _contentTypeForPath(videoFile.path),
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_multipartErrorMessage(response, 'Video upload failed'));
    }
  }

  Future<void> publishVideo(String contentId) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson('/content/videos/$contentId/publish');
  }

  Future<ContentVideoDetail> fetchVideoDetail(String contentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/content/videos/$contentId');
    return ContentVideoDetail.fromJson(
      Map<String, dynamic>.from(data['item'] as Map? ?? const {}),
    );
  }

  Future<List<ContentTranscriptTrack>> fetchVideoTranscripts(
    String contentId,
  ) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/content/videos/$contentId/transcripts');
    return (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) =>
              ContentTranscriptTrack.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<ContentTranscriptTrack> fetchVideoTranscriptTrack({
    required String contentId,
    required String languageCode,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/content/videos/$contentId/transcripts/$languageCode',
    );
    return ContentTranscriptTrack.fromJson(
      Map<String, dynamic>.from(data['track'] as Map? ?? const {}),
    );
  }

  Future<ContentTranscriptGenerationRequest> generateVideoTranscript(
    String contentId,
  ) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/videos/$contentId/transcript/generate',
    );
    return ContentTranscriptGenerationRequest.fromJson(
      Map<String, dynamic>.from(data),
    );
  }

  Future<ContentTranscriptTrack> translateVideoTranscript({
    required String contentId,
    required String languageCode,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/videos/$contentId/transcripts/$languageCode/translate',
    );
    return ContentTranscriptTrack.fromJson(
      Map<String, dynamic>.from(data['track'] as Map? ?? const {}),
    );
  }

  Future<ContentTranscriptTrack> updateVideoTranscript({
    required String contentId,
    required String languageCode,
    required List<ContentTranscriptSegment> segments,
    String? expectedUpdatedAt,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.patchJson(
      '/content/videos/$contentId/transcripts/$languageCode',
      body: <String, dynamic>{
        if ((expectedUpdatedAt ?? '').trim().isNotEmpty)
          'expectedUpdatedAt': expectedUpdatedAt!.trim(),
        'segments': segments.map((segment) => segment.toJson()).toList(),
      },
    );
    return ContentTranscriptTrack.fromJson(
      Map<String, dynamic>.from(data['track'] as Map? ?? const {}),
    );
  }

  Future<List<ContentTranscriptTrack>> fetchPodcastTranscripts(
    String contentId,
  ) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/content/podcasts/$contentId/transcripts',
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) =>
              ContentTranscriptTrack.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<ContentTranscriptTrack> fetchPodcastTranscriptTrack({
    required String contentId,
    required String languageCode,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson(
      '/content/podcasts/$contentId/transcripts/$languageCode',
    );
    return ContentTranscriptTrack.fromJson(
      Map<String, dynamic>.from(data['track'] as Map? ?? const {}),
    );
  }

  Future<ContentTranscriptGenerationRequest> generatePodcastTranscript(
    String contentId,
  ) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/podcasts/$contentId/transcript/generate',
    );
    return ContentTranscriptGenerationRequest.fromJson(
      Map<String, dynamic>.from(data),
    );
  }

  Future<ContentTranscriptTrack> translatePodcastTranscript({
    required String contentId,
    required String languageCode,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/podcasts/$contentId/transcripts/$languageCode/translate',
    );
    return ContentTranscriptTrack.fromJson(
      Map<String, dynamic>.from(data['track'] as Map? ?? const {}),
    );
  }

  Future<ContentTranscriptTrack> updatePodcastTranscript({
    required String contentId,
    required String languageCode,
    required List<ContentTranscriptSegment> segments,
    String? expectedUpdatedAt,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.patchJson(
      '/content/podcasts/$contentId/transcripts/$languageCode',
      body: <String, dynamic>{
        if ((expectedUpdatedAt ?? '').trim().isNotEmpty)
          'expectedUpdatedAt': expectedUpdatedAt!.trim(),
        'segments': segments.map((segment) => segment.toJson()).toList(),
      },
    );
    return ContentTranscriptTrack.fromJson(
      Map<String, dynamic>.from(data['track'] as Map? ?? const {}),
    );
  }

  Future<String> createUserPost({
    required String kind,
    required String title,
    String summary = '',
    String body = '',
  }) async {
    final client = _ref.read(apiClientProvider);
    try {
      final data = await client.postJson(
        '/content/posts',
        body: <String, dynamic>{
          'kind': kind,
          'title': title.trim(),
          'summary': summary.trim(),
          'body': body.trim(),
        },
      );
      final content = data['content'] as Map<String, dynamic>? ?? const {};
      return content['id']?.toString() ?? '';
    } on ApiException catch (e) {
      if (e.isServiceUnavailable) {
        throw const ApiException(
          'The content feature isn\'t set up on the server yet. '
          'Ask your admin to run the content migrations.',
          statusCode: 503,
        );
      }
      rethrow;
    }
  }

  Future<String> createPodcastDraft({
    required String title,
    required String summary,
    String body = '',
    String sourceLocale = 'und',
    List<String> translationTargets = const [],
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/podcasts',
      body: <String, dynamic>{
        'title': title.trim(),
        'summary': summary.trim(),
        'body': body.trim(),
        'sourceLocale': sourceLocale.trim(),
        'translationTargets': translationTargets,
      },
    );
    final content = data['content'] as Map<String, dynamic>? ?? const {};
    return content['id']?.toString() ?? '';
  }

  Future<void> uploadPostMedia({
    required String postId,
    required XFile mediaFile,
    int order = 0,
  }) async {
    final client = _ref.read(apiClientProvider);
    final token = client.token ?? '';
    if (token.isEmpty) {
      throw Exception('Not authenticated');
    }
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/content/posts/$postId/upload-media'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.fields['order'] = order.toString();
    request.files.add(
      await http.MultipartFile.fromPath(
        'media',
        mediaFile.path,
        filename: mediaFile.name,
        contentType: _contentTypeForPath(mediaFile.path),
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_multipartErrorMessage(response, 'Media upload failed'));
    }
  }

  Future<void> uploadPodcastCover({
    required String contentId,
    required XFile coverFile,
  }) async {
    final client = _ref.read(apiClientProvider);
    final token = client.token ?? '';
    if (token.isEmpty) {
      throw Exception('Not authenticated');
    }
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/content/podcasts/$contentId/upload-cover'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(
      await http.MultipartFile.fromPath(
        'cover',
        coverFile.path,
        filename: coverFile.name,
        contentType: _contentTypeForPath(coverFile.path),
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _multipartErrorMessage(response, 'Podcast cover upload failed'),
      );
    }
  }

  Future<void> uploadPodcastAudio({
    required String contentId,
    required XFile audioFile,
  }) async {
    final client = _ref.read(apiClientProvider);
    final token = client.token ?? '';
    if (token.isEmpty) {
      throw Exception('Not authenticated');
    }
    final baseUrl = client.baseUrl.replaceAll(RegExp(r'/$'), '');
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/content/podcasts/$contentId/upload-audio'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(
      await http.MultipartFile.fromPath(
        'audio',
        audioFile.path,
        filename: audioFile.name,
        contentType: _contentTypeForPath(audioFile.path),
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        _multipartErrorMessage(response, 'Podcast audio upload failed'),
      );
    }
  }

  Future<void> publishPodcast(String contentId) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson('/content/podcasts/$contentId/publish');
  }

  Future<ContentViewState> recordView(String contentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson('/content/items/$contentId/view');
    return ContentViewState(
      viewCount: (data['viewCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<ContentLikeState> likeContent(String contentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson('/content/items/$contentId/like');
    return ContentLikeState(
      likeCount: (data['likeCount'] as num?)?.toInt() ?? 0,
      likedByMe: data['likedByMe'] == true,
    );
  }

  Future<ContentLikeState> unlikeContent(String contentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.deleteJson('/content/items/$contentId/like');
    return ContentLikeState(
      likeCount: (data['likeCount'] as num?)?.toInt() ?? 0,
      likedByMe: data['likedByMe'] == true,
    );
  }

  Future<void> hideContent(String contentId) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson('/content/items/$contentId/hide');
  }

  Future<void> deleteContent(String contentId) async {
    final client = _ref.read(apiClientProvider);
    await client.deleteJson('/content/items/$contentId');
  }

  Future<void> editContent({
    required String contentId,
    required String title,
    String summary = '',
    String body = '',
  }) async {
    final client = _ref.read(apiClientProvider);
    await client.patchJson(
      '/content/items/$contentId',
      body: <String, dynamic>{
        'title': title.trim(),
        'summary': summary.trim(),
        'body': body.trim(),
      },
    );
  }

  Future<List<ContentCommentItem>> fetchComments(String contentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/content/items/$contentId/comments');
    return (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (row) => ContentCommentItem.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<AddedContentComment> addComment({
    required String contentId,
    required String body,
    String? parentId,
  }) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson(
      '/content/items/$contentId/comments',
      body: <String, dynamic>{'body': body.trim(), 'parentId': parentId},
    );
    final comment = ContentCommentItem.fromJson(
      Map<String, dynamic>.from(data['comment'] as Map? ?? const {}),
    );
    return AddedContentComment(
      comment: comment,
      commentCount: (data['commentCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<ContentLikeState> likeComment(String commentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.postJson('/content/comments/$commentId/like');
    return ContentLikeState(
      likeCount: (data['likeCount'] as num?)?.toInt() ?? 0,
      likedByMe: data['likedByMe'] == true,
    );
  }

  Future<ContentLikeState> unlikeComment(String commentId) async {
    final client = _ref.read(apiClientProvider);
    final data = await client.deleteJson('/content/comments/$commentId/like');
    return ContentLikeState(
      likeCount: (data['likeCount'] as num?)?.toInt() ?? 0,
      likedByMe: data['likedByMe'] == true,
    );
  }
}
