import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/network/api_exception.dart';

void main() {
  group('ApiException', () {
    test('isClientError for 4xx codes', () {
      expect(const ApiException('e', statusCode: 400).isClientError, isTrue);
      expect(const ApiException('e', statusCode: 499).isClientError, isTrue);
      expect(const ApiException('e', statusCode: 500).isClientError, isFalse);
    });

    test('isServerError for 5xx codes', () {
      expect(const ApiException('e', statusCode: 500).isServerError, isTrue);
      expect(const ApiException('e', statusCode: 503).isServerError, isTrue);
      expect(const ApiException('e', statusCode: 400).isServerError, isFalse);
    });

    test('specific status checks', () {
      expect(const ApiException('e', statusCode: 401).isUnauthorized, isTrue);
      expect(const ApiException('e', statusCode: 403).isForbidden, isTrue);
      expect(const ApiException('e', statusCode: 404).isNotFound, isTrue);
      expect(const ApiException('e', statusCode: 409).isConflict, isTrue);
      expect(const ApiException('e', statusCode: 429).isRateLimited, isTrue);
    });

    test('null statusCode returns false for all checks', () {
      const e = ApiException('error');
      expect(e.isClientError, isFalse);
      expect(e.isServerError, isFalse);
      expect(e.isUnauthorized, isFalse);
    });

    test('toString includes status code', () {
      expect(
        const ApiException('fail', statusCode: 404).toString(),
        'ApiException(404): fail',
      );
    });
  });

  group('NetworkException', () {
    test('has null statusCode', () {
      const e = NetworkException('offline');
      expect(e.statusCode, isNull);
      expect(e.toString(), 'NetworkException: offline');
    });
  });

  group('TimeoutException', () {
    test('has default message', () {
      const e = TimeoutException();
      expect(e.message, 'Request timed out');
      expect(e.statusCode, isNull);
    });
  });

  group('userFriendlyMessage', () {
    test('timeout gives connection hint', () {
      expect(
        userFriendlyMessage(const TimeoutException()),
        contains('taking too long'),
      );
    });

    test('network error gives connection hint', () {
      expect(
        userFriendlyMessage(const NetworkException('err')),
        contains('internet connection'),
      );
    });

    test('401 gives session hint', () {
      expect(
        userFriendlyMessage(const ApiException('x', statusCode: 401)),
        contains('session'),
      );
    });

    test('429 gives rate limit hint', () {
      expect(
        userFriendlyMessage(const ApiException('x', statusCode: 429)),
        contains('Too many requests'),
      );
    });

    test('500 gives server hint', () {
      expect(
        userFriendlyMessage(const ApiException('x', statusCode: 500)),
        contains('our end'),
      );
    });

    test('generic error passes through message', () {
      expect(
        userFriendlyMessage(const ApiException('Email taken', statusCode: 400)),
        'Email taken',
      );
    });
  });
}
