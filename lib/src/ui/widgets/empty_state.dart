import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// "할 일 없음" 류의 빈 상태 일관 위젯. 모든 화면이 같은 시각 언어를 쓰도록 강제한다
/// (디자인 점수 § 일관성).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.tone,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 빈 상태에서 바로 할 수 있는 행동 (예: "새 할 일" 버튼). 읽고 끝나는 빈 화면을
  /// 없애기 위한 슬롯 (UX 감사 — 빈 상태 CTA 없음).
  final Widget? action;

  /// null 이면 [ColorScheme.primary] 사용. 카테고리 색 등 의미 강조용으로 주입 가능.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.colorScheme.primary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppTokens.radiusL),
              ),
              child: Icon(icon, size: 36, color: color),
            ),
            const SizedBox(height: AppTokens.space20),
            Text(
              title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppTokens.space8),
              Text(
                subtitle!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppTokens.space20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 불러오기 실패 공통 화면 — 사용자 문구 + "다시 시도".
///
/// 예외 원문(`'$e'`)을 화면에 그대로 찍던 화면들(오늘·카테고리·상세)을 이걸로 모았다
/// (UX 감사 B8). 원문은 개발자용이라 로그로만 남긴다.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.title, this.error, this.onRetry});

  final String title;

  /// 로그용 원인. 화면에는 표시하지 않는다.
  final Object? error;

  /// null 이면 "다시 시도" 버튼을 숨긴다.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (error != null) debugPrint('[haru] $title: $error');
    return EmptyState(
      icon: Icons.error_outline,
      title: title,
      subtitle: '잠시 뒤 다시 시도해 주세요.',
      tone: Theme.of(context).colorScheme.error,
      action: onRetry == null
          ? null
          : OutlinedButton.icon(
              key: const ValueKey('error-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('다시 시도'),
            ),
    );
  }
}
