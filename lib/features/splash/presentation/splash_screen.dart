import 'dart:async';

import 'package:flutter/material.dart';

class TalkflixSplashGate extends StatefulWidget {
  const TalkflixSplashGate({super.key, required this.child});

  final Widget child;

  @override
  State<TalkflixSplashGate> createState() => _TalkflixSplashGateState();
}

class _TalkflixSplashGateState extends State<TalkflixSplashGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  Timer? _timer;
  var _showSplash = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..forward();
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _scale = Tween<double>(
      begin: 0.9,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _timer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _showSplash = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;
    return TalkflixSplashScreen(opacity: _opacity, scale: _scale);
  }
}

class TalkflixSplashScreen extends StatelessWidget {
  const TalkflixSplashScreen({
    super.key,
    required this.opacity,
    required this.scale,
  });

  final Animation<double> opacity;
  final Animation<double> scale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeTransition(
                opacity: opacity,
                child: ScaleTransition(
                  scale: scale,
                  child: Image.asset(
                    'assets/images/talkflix_logo.png',
                    width: 90,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FadeTransition(
                opacity: opacity,
                child: ScaleTransition(
                  scale: scale,
                  child: Text(
                    'TALKFLIX',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
