import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/features/profile/presentation/profile_qr_screen.dart';

void main() {
  group('profile QR payloads', () {
    test('builds the Talkflix profile QR payload', () {
      expect(
        buildProfileQrPayload('user_42'),
        'talkflix://app/app/profile/user_42',
      );
    });

    test('parses the Talkflix scheme payload', () {
      expect(
        parseProfileQrUserId('talkflix://app/app/profile/user_42'),
        'user_42',
      );
    });

    test('parses bare app profile routes', () {
      expect(parseProfileQrUserId('/app/profile/user_42'), 'user_42');
    });

    test('rejects unrelated QR payloads', () {
      expect(parseProfileQrUserId('https://talkflix.cc'), isNull);
      expect(parseProfileQrUserId('not-a-profile'), isNull);
    });
  });
}
