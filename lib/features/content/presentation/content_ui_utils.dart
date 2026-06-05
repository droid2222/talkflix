import '../../../core/network/api_exception.dart';

String userFriendlyMessageFromObject(Object error) {
  if (error is ApiException) {
    return userFriendlyMessage(error);
  }
  final text = error.toString().replaceFirst('Exception: ', '').trim();
  return text.isEmpty ? 'Something went wrong. Please try again.' : text;
}
