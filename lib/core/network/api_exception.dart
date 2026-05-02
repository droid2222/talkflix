/// Base class for all API-related exceptions.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  bool get isClientError =>
      statusCode != null && statusCode! >= 400 && statusCode! < 500;
  bool get isServerError =>
      statusCode != null && statusCode! >= 500;
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thrown when a network-level failure occurs (no response received).
class NetworkException extends ApiException {
  const NetworkException(super.message, {super.cause})
      : super(statusCode: null);

  @override
  String toString() => 'NetworkException: $message';
}

/// Thrown when a request times out.
class TimeoutException extends ApiException {
  const TimeoutException([super.message = 'Request timed out'])
      : super(statusCode: null);

  @override
  String toString() => 'TimeoutException: $message';
}

/// User-friendly error message mapper.
String userFriendlyMessage(ApiException error) {
  if (error is TimeoutException) {
    return 'The server is taking too long. Please check your connection and try again.';
  }
  if (error is NetworkException) {
    return 'Could not reach the server. Please check your internet connection.';
  }
  if (error.isUnauthorized) {
    return 'Your session has expired. Please sign in again.';
  }
  if (error.isForbidden) {
    return 'You don\'t have permission to do that.';
  }
  if (error.isNotFound) {
    return 'The requested resource was not found.';
  }
  if (error.isRateLimited) {
    return 'Too many requests. Please wait a moment and try again.';
  }
  if (error.isServerError) {
    return 'Something went wrong on our end. Please try again later.';
  }
  return error.message;
}
