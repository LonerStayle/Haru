import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// 오늘 화면 상단 진척 — **한 줄 글 + 얇은 막대** (UX Phase 1).
///
/// 예전 원형 링 카드는 첫 화면 세로 공간을 ~90dp 먹으면서 알려 주는 건 숫자 하나였다.
/// 이제 "오늘 3/7 완료 · 진행중 1 · 4개 남음" 한 줄과 4dp 막대로 같은 정보를 준다.
/// 막대는 완료만 진하게, 진행중은 옅게 이어 그린다(완료율 정직 유지 + 진행 가시화).
/// [total] 이 0 이면(오늘 task 없음) 빈 위젯.
class TodayProgressSummary extends StatelessWidget {
  const TodayProgressSummary({
    super.key,
    required this.done,
    required this.total,
    this.inProgress = 0,
  });

  final int done;
  final int inProgress;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isComplete = done >= total;
    final remaining = total - done;
    final ratio = (done / total).clamp(0.0, 1.0);
    final ipRatio = (inProgress.clamp(0, total - done) / total).clamp(0.0, 1.0);
    final color = isComplete ? AppPalette.success : scheme.primary;
    final muted = scheme.onSurface.withValues(alpha: 0.62);

    final text = isComplete
        ? '오늘 할 일 모두 끝냈어요 🎉'
        : ['$remaining개 남음', if (inProgress > 0) '진행중 $inProgress'].join(' · ');

    return Column(
      key: const ValueKey('today-progress-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$done/$total 완료',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: isComplete ? color : scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: AppTokens.space8),
            Expanded(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            Text(
              '${(ratio * 100).round()}%',
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          child: SizedBox(
            height: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: scheme.outline.withValues(alpha: 0.35)),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (ratio + ipRatio).clamp(0.0, 1.0),
                  child: ColoredBox(color: color.withValues(alpha: 0.3)),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: ratio,
                  child: ColoredBox(color: color),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
