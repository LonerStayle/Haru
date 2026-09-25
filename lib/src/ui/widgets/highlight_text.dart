import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// [text] 안에서 [query] 와 일치하는 부분(대소문자 무시)을 강조해 그린다 — 검색 결과용.
///
/// [query] 가 비었거나 일치가 없으면 평범한 [Text] 와 같다.
class HighlightText extends StatelessWidget {
  const HighlightText(
    this.text, {
    super.key,
    required this.query,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final String? query;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final q = query?.trim() ?? '';
    final ranges = matchRanges(text, q);
    if (ranges.isEmpty) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }
    final hi = TextStyle(
      backgroundColor: AppPalette.accent.withValues(alpha: 0.22),
      fontWeight: FontWeight.w700,
    );
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in ranges) {
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      spans.add(TextSpan(text: text.substring(start, end), style: hi));
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  /// [text] 에서 [query] 가 나오는 모든 (시작, 끝) — 겹치지 않게 앞에서부터.
  static List<(int, int)> matchRanges(String text, String query) {
    if (query.isEmpty) return const [];
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final out = <(int, int)>[];
    var from = 0;
    while (true) {
      final i = lower.indexOf(q, from);
      if (i < 0) break;
      out.add((i, i + q.length));
      from = i + q.length;
    }
    return out;
  }
}
