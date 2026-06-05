import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/realtime/direct_call_push_service.dart';

Future<void> main() async {
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.directCallsEnabled) {
    unawaited(initializeDirectCallAndroidPushRuntime());
  }
  runApp(const ProviderScope(child: TalkflixApp()));
}
