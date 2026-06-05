import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final RegExp _contentLinkPattern = RegExp(
  r'((?:https?:\/\/|www\.)[^\s<]+|(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:\/[^\s<]*)?)',
  caseSensitive: false,
);

class ContentLinkText extends StatefulWidget {
  const ContentLinkText({
    super.key,
    required this.text,
    this.style,
    this.textAlign = TextAlign.start,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;
  final TextOverflow overflow;

  @override
  State<ContentLinkText> createState() => _ContentLinkTextState();
}

class _ContentLinkTextState extends State<ContentLinkText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _openUrl(String rawUrl) async {
    final uri = _normalizeContentLink(rawUrl);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${uri.toString()}')),
      );
    }
  }

  TextSpan _buildTextSpan({required bool interactive}) {
    if (interactive) {
      _disposeRecognizers();
    }
    final defaultStyle = widget.style ?? DefaultTextStyle.of(context).style;
    final spans = <InlineSpan>[];
    final rawText = widget.text;
    var cursor = 0;
    for (final match in _contentLinkPattern.allMatches(rawText)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: rawText.substring(cursor, match.start),
            style: defaultStyle,
          ),
        );
      }
      final rawMatch = rawText.substring(match.start, match.end);
      final cleaned = _trimTrailingLinkPunctuation(rawMatch);
      final trailing = rawMatch.substring(cleaned.length);
      final uri = _normalizeContentLink(cleaned);
      if (uri == null) {
        spans.add(TextSpan(text: rawMatch, style: defaultStyle));
      } else {
        TapGestureRecognizer? recognizer;
        if (interactive) {
          recognizer = TapGestureRecognizer()..onTap = () => _openUrl(cleaned);
          _recognizers.add(recognizer);
        }
        spans.add(
          TextSpan(
            text: cleaned,
            style: defaultStyle.copyWith(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
            recognizer: recognizer,
          ),
        );
        if (trailing.isNotEmpty) {
          spans.add(TextSpan(text: trailing, style: defaultStyle));
        }
      }
      cursor = match.end;
    }
    if (cursor < rawText.length) {
      spans.add(TextSpan(text: rawText.substring(cursor), style: defaultStyle));
    }
    return TextSpan(style: defaultStyle, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: _buildTextSpan(interactive: true),
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}

class ExpandableContentLinkText extends StatefulWidget {
  const ExpandableContentLinkText({
    super.key,
    required this.text,
    this.style,
    this.collapsedMaxLines = 3,
  });

  final String text;
  final TextStyle? style;
  final int collapsedMaxLines;

  @override
  State<ExpandableContentLinkText> createState() =>
      _ExpandableContentLinkTextState();
}

class _ExpandableContentLinkTextState extends State<ExpandableContentLinkText> {
  bool _expanded = false;

  bool _overflows(BoxConstraints constraints) {
    final painter = TextPainter(
      text: _buildTextSpan(context, widget.text, widget.style),
      maxLines: widget.collapsedMaxLines,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: constraints.maxWidth);
    return painter.didExceedMaxLines;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _overflows(constraints);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ContentLinkText(
              text: widget.text,
              style: style,
              maxLines: _expanded ? null : widget.collapsedMaxLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflows || _expanded) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'See less' : 'See more',
                  style: (style ?? Theme.of(context).textTheme.bodyMedium)
                      ?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

TextSpan _buildTextSpan(BuildContext context, String text, TextStyle? style) {
  final defaultStyle = style ?? DefaultTextStyle.of(context).style;
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in _contentLinkPattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(
        TextSpan(
          text: text.substring(cursor, match.start),
          style: defaultStyle,
        ),
      );
    }
    final rawMatch = text.substring(match.start, match.end);
    final cleaned = _trimTrailingLinkPunctuation(rawMatch);
    final trailing = rawMatch.substring(cleaned.length);
    spans.add(TextSpan(text: cleaned, style: defaultStyle));
    if (trailing.isNotEmpty) {
      spans.add(TextSpan(text: trailing, style: defaultStyle));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: defaultStyle));
  }
  return TextSpan(style: defaultStyle, children: spans);
}

String _trimTrailingLinkPunctuation(String text) {
  var result = text.trim();
  while (result.isNotEmpty && '.,!?;:)]}'.contains(result[result.length - 1])) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

Uri? _normalizeContentLink(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return null;
  final prefixed = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(prefixed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' &&
      scheme != 'https' &&
      scheme != 'mailto' &&
      scheme != 'tel') {
    return null;
  }
  return uri;
}
