import 'dart:convert';
import 'dart:typed_data';

import '../config/app_config.dart';

Uint8List? tryDecodeDataUrl(String value) {
  final match = RegExp(r'^data:.*?;base64,(.*)$').firstMatch(value);
  if (match == null) return null;
  try {
    return base64Decode(match.group(1)!);
  } catch (_) {
    return null;
  }
}

String resolveMediaUrl(String value) {
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (value.startsWith('/')) {
    return '${AppConfig.apiBaseUrl}$value';
  }
  return value;
}

String bytesToDataUrl(Uint8List bytes, String mimeType) {
  return 'data:$mimeType;base64,${base64Encode(bytes)}';
}
