import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// 오늘 화면 상단 진척 요약 카드 — 원형 진행 링 + "오늘 N/M 완료" 텍스트.
///
/// [total] 은 오늘 task(메모 제외) 수, [done] 은 그중 완료 수, [inProgress] 는 진행중 수.
/// **링은 완료만 진하게 채우고, 진행중은 옅은 세그먼트로 별도 표기**(대표님 확정 — 완료율
/// 정직 유지 + 진행 가시화). total 이 0 이면 (오늘 task 가 없음) 안전망으로 빈 위젯.
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
    final ratio = total == 0 ? 0.0 : done / total;
    // 진행중 세그먼트 — 완료 arc 뒤에 이어 옅게 그린다. 완료+진행중이 total 을 넘지 않도록 클램프.
    final inProgressRatio = total == 0
        ? 0.0
        : (inProgress.clamp(0, total - done)) / total;

    // 완료 시 성공 그린(= daily 카테고리 hue), 진행 중엔 accent 블루.
    const successColor = Color(0xFF10B981);
    final ringColor = isComplete ? successColor : scheme.primary;

    return Container(
      key: const ValueKey('today-progress-summary'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space16,
        vertical: AppTokens.space16,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTokens.radiusL),
        border: Border.all(
          color: ringColor.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.35 : 0.22,
          ),
          width: AppTokens.hairline,
        ),
      ),
      child: Row(
        children: [
          _ProgressRing(
            ratio: ratio,
            inProgressRatio: inProgressRatio,
            color: ringColor,
            track: scheme.outline,
            isComplete: isComplete,
            done: done,
            total: total,
            labelStyle: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: AppTokens.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isComplete ? '오늘 할 일 모두 끝냈어요' : '오늘 $done / $total 완료',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isComplete ? successColor : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: AppTokens.space2),
                Text(
                  isComplete
                      ? '깔끔하게 비웠어요. 잘하셨어요 🎉'
                      : inProgress > 0
                      ? '$remaining개 남음 · 진행중 $inProgress'
                      : '$remaining개 남았어요',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // 우측 큰 퍼센트 — 한눈 가시성 보강.
          Text(
            '${(ratio * 100).round()}%',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: ringColor,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.ratio,
    required this.inProgressRatio,
    required this.color,
    required this.track,
    required this.isComplete,
    required this.done,
    required this.total,
    required this.labelStyle,
  });

  final double ratio;
  final double inProgressRatio;
  final Color color;
  final Color track;
  final bool isComplete;
  final int done;
  final int total;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          ratio: ratio,
          inProgressRatio: inProgressRatio,
          color: color,
          track: track,
        ),
        child: Center(
          child: isComplete
              ? Icon(Icons.check_rounded, size: 24, color: color)
              : Text('$done/$total', style: labelStyle),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.ratio,
    required this.inProgressRatio,
    required this.color,
    required this.track,
  });

  final double ratio;
  final double inProgressRatio;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 6.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = -math.pi / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track.withValues(alpha: 0.5)
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    final doneSweep = (ratio.clamp(0.0, 1.0)) * 2 * math.pi;
    final ipSweep = (inProgressRatio.clamp(0.0, 1.0)) * 2 * math.pi;

    // 진행중 세그먼트 — 완료 arc 뒤에 옅은 색으로 먼저(아래 레이어) 그린다.
    if (ipSweep > 0) {
      final ipPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.28)
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, start + doneSweep, ipSweep, false, ipPaint);
    }

    // 완료 arc — 진한 색.
    if (doneSweep > 0) {
      final progressPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, start, doneSweep, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio ||
      old.inProgressRatio != inProgressRatio ||
      old.color != color ||
      old.track != track;
}
