import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_client.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/feature_scaffold.dart';

enum FollowListType { followers, following }

class FollowListItem {
  const FollowListItem({
    required this.id,
    required this.displayName,
    required this.username,
    required this.country,
    required this.profilePhotoUrl,
  });

  final String id;
  final String displayName;
  final String username;
  final String country;
  final String profilePhotoUrl;

  factory FollowListItem.fromJson(Map<String, dynamic> json) {
    return FollowListItem(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? 'User',
      username: json['username']?.toString() ?? 'user',
      country: json['country']?.toString() ?? '',
      profilePhotoUrl: json['profilePhotoUrl']?.toString() ?? '',
    );
  }
}

final followListProvider = FutureProvider.family
    .autoDispose<
      List<FollowListItem>,
      ({String userId, FollowListType type, String query})
    >((ref, args) async {
      final endpoint = args.type == FollowListType.followers
          ? '/users/${args.userId}/followers'
          : '/users/${args.userId}/following';
      final response = await ref
          .read(apiClientProvider)
          .getJson(endpoint, queryParameters: {'q': args.query});
      return (response['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FollowListItem.fromJson)
          .toList();
    });

class FollowListScreen extends ConsumerStatefulWidget {
  const FollowListScreen({
    super.key,
    required this.userId,
    required this.type,
    this.titleName,
  });

  final String userId;
  final FollowListType type;
  final String? titleName;

  @override
  ConsumerState<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends ConsumerState<FollowListScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(
      followListProvider((
        userId: widget.userId,
        type: widget.type,
        query: _query,
      )),
    );
    final title = widget.type == FollowListType.followers
        ? 'Followers'
        : 'Following';

    return FeatureScaffold(
      title: title,
      children: [
        SectionCard(
          title: title,
          subtitle: widget.titleName,
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search ${title.toLowerCase()}',
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
              const SizedBox(height: 16),
              items.when(
                data: (value) {
                  if (value.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text('No users found.'),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () => ref.refresh(
                      followListProvider((
                        userId: widget.userId,
                        type: widget.type,
                        query: _query,
                      )).future,
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: value.map((item) {
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          onTap: () => context.push('/app/profile/${item.id}'),
                          leading: AppAvatar(
                            label: item.displayName,
                            imageUrl: item.profilePhotoUrl,
                          ),
                          title: Text(item.displayName),
                          subtitle: Text(
                            '@${item.username}${item.country.isEmpty ? '' : ' • ${item.country}'}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                        );
                      }).toList(),
                    ),
                  );
                },
                error: (error, stackTrace) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error.toString()),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => ref.refresh(
                        followListProvider((
                          userId: widget.userId,
                          type: widget.type,
                          query: _query,
                        )),
                      ),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
