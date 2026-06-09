import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openPublicHome(BuildContext context) async {
  if (kIsWeb) {
    final opened = await launchUrl(
      Uri.parse('${Uri.base.origin}/'),
      webOnlyWindowName: '_self',
    );
    if (opened || !context.mounted) return;
  }

  if (context.mounted) {
    context.go('/login');
  }
}
