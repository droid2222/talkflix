import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkflix_flutter/core/config/app_config.dart';

void main() {
  test('local QA tools follow Flutter debug mode only', () {
    expect(AppConfig.localQaToolsEnabled, kDebugMode);
  });

  test('default Pro IAP product IDs match the store setup', () {
    expect(AppConfig.proProductIds, const <String>[
      'talkflix_pro_monthly_v2',
      'talkflix_pro_6_months',
      'talkflix_pro_yearly',
    ]);
  });
}
