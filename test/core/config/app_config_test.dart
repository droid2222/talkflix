import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/config/app_config.dart';

void main() {
  test('local QA tools follow Flutter debug mode only', () {
    expect(AppConfig.localQaToolsEnabled, kDebugMode);
  });
}
