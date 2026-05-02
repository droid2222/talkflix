import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../../core/network/api_client.dart';

final contentRepositoryProvider = Provider<ContentRepository>((ref) {
  return ContentRepository(ref);
});

final publishedVideosProvider = FutureProvider<List<ContentVideoItem>>((
  ref,
) async {
  return ref.read(contentRepositoryProvider).fetchPublishedVideos();
});

class ContentVideoItem {
  const ContentVideoItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.sourceLocale,
    required this.videoUrl,
    required this.publishedAt,
  });

  final String id;
  final String title;
  final String summary;
  final String sourceLocale;
  final String videoUrl;
  final DateTime? publishedAt;

  factory ContentVideoItem.fromListJson(Map<String, dynamic> json) {
    return ContentVideoItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      sourceLocale: json['sourceLocale']?.toString() ?? 'und',
      videoUrl: json['videoUrl']?.toString() ?? '',
      publishedAt: _parseDate(json['publishedAt']),
    );
  }

  static DateTime? _parseDate(dynamic raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toLocal();
  }
}

class UserPostItem {
  const UserPostItem({
    required this.id,
    required this.kind,
    required this.authorName,
    required this.title,
    required this.summary,
    required this.body,
    required this.mediaUrl,
    required this.mediaMimeType,
    required this.publishedAt,
  });

  final String id;
  final String kind;
  final String authorName;
  final String title;
  final String summary;
  final String body;
  final String mediaUrl;
  final String mediaMimeType;
  final DateTime? publishedAt;

  factory UserPostItem.fromJson(Map<String, dynamic> json) {
    return UserPostItem(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'text',
      authorName: json['authorName']?.toString() ?? 'User',
      title: json['title']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      mediaUrl: json['mediaUrl']?.toString() ?? '',
      mediaMimeType: json['mediaMimeType']?.toString() ?? '',
      publishedAt: ContentVideoItem._parseDate(json['publishedAt']),
    );
  }
}

final userPostsProvider = FutureProvider<List<UserPostItem>>((ref) async {
  return ref.read(contentRepositoryProvider).fetchUserPosts();
});

class CreatedVideoDraft {
  const CreatedVideoDraft({required this.id, required this.status});

  final String id;
  final String status;
}

class ContentRepository {
  const ContentRepository(this._ref);

  final Ref _ref;

  Future<List<ContentVideoItem>> fetchPublishedVideos() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/content/videos');
    final items = (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => ContentVideoItem.fromListJson(Map<String, dynamic>.from(row)))
        .toList();
    return items;
  }

  Future<List<UserPostItem>> fetchUserPosts() async {
    final client = _ref.read(apiClientProvider);
    final data = await client.getJson('/content/posts');
    final items = (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => UserPostItem.fromJson(Map<String, dynamic>.from(row)))
        .toList();
    return items;
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
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(payload['message']?.toString() ?? 'Video upload failed');
    }
  }

  Future<void> publishVideo(String contentId) async {
    final client = _ref.read(apiClientProvider);
    await client.postJson('/content/videos/$contentId/publish');
  }

  Future<String> createUserPost({
    required String kind,
    required String title,
    String summary = '',
    String body = '',
  }) async {
    final client = _ref.read(apiClientProvider);
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
  }

  Future<void> uploadPostMedia({
    required String postId,
    required XFile mediaFile,
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
    request.files.add(
      await http.MultipartFile.fromPath(
        'media',
        mediaFile.path,
        filename: mediaFile.name,
      ),
    );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(payload['message']?.toString() ?? 'Media upload failed');
    }
  }
}

