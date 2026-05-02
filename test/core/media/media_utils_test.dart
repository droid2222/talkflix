import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/media/media_utils.dart';

void main() {
  group('tryDecodeDataUrl', () {
    test('decodes valid data URL', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
      final result = tryDecodeDataUrl(dataUrl);
      expect(result, isNotNull);
      expect(result, bytes);
    });

    test('returns null for non-data-url string', () {
      expect(tryDecodeDataUrl('https://example.com/img.png'), isNull);
    });

    test('returns null for invalid base64', () {
      expect(tryDecodeDataUrl('data:image/png;base64,!!!invalid'), isNull);
    });
  });

  group('resolveMediaUrl', () {
    test('returns absolute http URLs unchanged', () {
      expect(resolveMediaUrl('http://example.com/a.jpg'), 'http://example.com/a.jpg');
      expect(resolveMediaUrl('https://cdn.example.com/b.jpg'), 'https://cdn.example.com/b.jpg');
    });

    test('prepends base URL for paths starting with /', () {
      final result = resolveMediaUrl('/uploads/photo.jpg');
      expect(result, contains('/uploads/photo.jpg'));
      expect(result, startsWith('http'));
    });

    test('returns other strings as-is', () {
      expect(resolveMediaUrl('data:image/png;base64,abc'), 'data:image/png;base64,abc');
    });
  });

  group('bytesToDataUrl', () {
    test('creates valid data URL', () {
      final bytes = Uint8List.fromList([10, 20, 30]);
      final result = bytesToDataUrl(bytes, 'audio/wav');
      expect(result, startsWith('data:audio/wav;base64,'));
      expect(tryDecodeDataUrl(result), bytes);
    });
  });
}
