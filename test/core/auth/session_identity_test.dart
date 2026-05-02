import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/auth/session_identity.dart';

void main() {
  group('parseSessionIdentityFromToken', () {
    test('extracts user and session ids from JWT payload', () {
      final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
      final payload = base64Url.encode(
        utf8.encode('{"sub":"103","sid":"session-103"}'),
      );
      final token = '$header.$payload.signature';

      final identity = parseSessionIdentityFromToken(token);

      expect(identity.userId, '103');
      expect(identity.sessionId, 'session-103');
      expect(identity.isValid, isTrue);
    });

    test('returns empty identity for missing session id', () {
      final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
      final payload = base64Url.encode(utf8.encode('{"sub":"103"}'));
      final token = '$header.$payload.signature';

      final identity = parseSessionIdentityFromToken(token);

      expect(identity.isValid, isFalse);
      expect(identity.userId, '103');
      expect(identity.sessionId, isEmpty);
    });
  });
}
