String compactCount(int value) {
  final normalized = value < 0 ? 0 : value;
  if (normalized >= 1000000000) {
    final amount = normalized / 1000000000;
    return '${_trimCompactDecimal(amount)}B';
  }
  if (normalized >= 1000000) {
    final amount = normalized / 1000000;
    return '${_trimCompactDecimal(amount)}M';
  }
  if (normalized >= 1000) {
    final amount = normalized / 1000;
    return '${_trimCompactDecimal(amount)}K';
  }
  return normalized.toString();
}

String _trimCompactDecimal(double value) {
  final fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}
