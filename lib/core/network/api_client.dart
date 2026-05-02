import 'dart:async' as async show TimeoutException;
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../auth/session_controller.dart';
import 'api_exception.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return ApiClient(baseUrl: AppConfig.apiBaseUrl, token: session.token);
});

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
    this.defaultTimeout = const Duration(seconds: 15),
    this.maxRetries = 2,
  }) : _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _httpClient;

  /// Default timeout per request attempt.
  final Duration defaultTimeout;

  /// Max retry attempts for retryable failures (network errors, 5xx, 429).
  final int maxRetries;

  Uri _uri(String path, [Map<String, String>? queryParameters]) {
    final normalizedBase = baseUrl.replaceAll(RegExp(r'/$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse(
      '$normalizedBase$normalizedPath',
    ).replace(queryParameters: queryParameters);
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
    int? retries,
  }) {
    return _withRetry(
      retries: retries,
      action: () async {
        final response = await _httpClient
            .get(_uri(path, queryParameters), headers: _headers())
            .timeout(timeout ?? defaultTimeout);
        return _decode(response);
      },
    );
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    int? retries,
  }) {
    return _withRetry(
      retries: retries,
      action: () async {
        final response = await _httpClient
            .post(
              _uri(path),
              headers: _headers(json: true),
              body: jsonEncode(body ?? <String, dynamic>{}),
            )
            .timeout(timeout ?? defaultTimeout);
        return _decode(response);
      },
    );
  }

  Future<Map<String, dynamic>> patchJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    int? retries,
  }) {
    return _withRetry(
      retries: retries,
      action: () async {
        final response = await _httpClient
            .patch(
              _uri(path),
              headers: _headers(json: true),
              body: jsonEncode(body ?? <String, dynamic>{}),
            )
            .timeout(timeout ?? defaultTimeout);
        return _decode(response);
      },
    );
  }

  Future<Map<String, dynamic>> deleteJson(
    String path, {
    Duration? timeout,
    int? retries,
  }) {
    return _withRetry(
      retries: retries,
      action: () async {
        final response = await _httpClient
            .delete(_uri(path), headers: _headers())
            .timeout(timeout ?? defaultTimeout);
        return _decode(response);
      },
    );
  }

  Map<String, String> _headers({bool json = false}) {
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Map<String, dynamic> _decode(http.Response response) {
    final dynamic payload = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    final data = payload is Map<String, dynamic>
        ? payload
        : <String, dynamic>{'data': payload};

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }

    throw ApiException(
      data['message']?.toString() ?? 'Request failed',
      statusCode: response.statusCode,
    );
  }

  /// Retries on network errors, timeouts, 5xx, and 429 with exponential backoff.
  Future<Map<String, dynamic>> _withRetry({
    int? retries,
    required Future<Map<String, dynamic>> Function() action,
  }) async {
    final maxAttempts = (retries ?? maxRetries) + 1;
    ApiException? lastError;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await action();
      } on async.TimeoutException catch (_) {
        lastError = const TimeoutException();
        if (attempt == maxAttempts - 1) throw lastError;
      } on ApiException catch (error) {
        lastError = error;
        if (!_isRetryable(error) || attempt == maxAttempts - 1) rethrow;
      } on Exception catch (error) {
        lastError = NetworkException(
          'Network error: ${error.runtimeType}',
          cause: error,
        );
        if (attempt == maxAttempts - 1) throw lastError;
      }

      // Exponential backoff: 500ms, 1500ms, 3500ms, ...
      final delay = Duration(
        milliseconds: (500 * pow(2, attempt)).toInt() + Random().nextInt(500),
      );
      if (kDebugMode) {
        // ignore: avoid_print
        print('[ApiClient] Retry ${attempt + 1}/$maxRetries after ${delay.inMilliseconds}ms');
      }
      await Future<void>.delayed(delay);
    }

    throw lastError ?? const ApiException('Unknown error');
  }

  bool _isRetryable(ApiException error) {
    if (error is NetworkException || error is TimeoutException) return true;
    return error.isServerError || error.isRateLimited;
  }
}
