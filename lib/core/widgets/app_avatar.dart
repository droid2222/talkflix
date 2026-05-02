import 'package:flutter/material.dart';

import '../media/media_utils.dart';

class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.label,
    this.imageUrl,
    this.radius = 20,
  });

  final String label;
  final String? imageUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final safeLabel = label.trim().isEmpty ? 'U' : label.trim();
    final safeImageUrl = (imageUrl ?? '').trim();

    return CircleAvatar(
      radius: radius,
      backgroundImage: safeImageUrl.isNotEmpty
          ? NetworkImage(resolveMediaUrl(safeImageUrl))
          : null,
      child: safeImageUrl.isEmpty
          ? Text(safeLabel.characters.first.toUpperCase())
          : null,
    );
  }
}
