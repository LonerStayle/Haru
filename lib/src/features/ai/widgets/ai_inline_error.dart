import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../settings/settings_sheet.dart';
import '../ai_providers.dart';

/// AI 호출 실패 안내 한 줄 — "AI 응답을 받지 못했어요 · 설정에서 확인" + [설정 열기].
///
/// 자동으로 다른 경로로 넘어가지 않는다. 문구는 준비 상태(한도·로그인 풀림)에 맞춘다.
class AiInlineError extends ConsumerWidget {
  const AiInlineError({super.key, this.message});

  /// 상태 문구 대신 쓸 문구 (예: "할 일을 찾지 못했어요").
  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = message ?? ref.watch(aiReadinessProvider).failureHint;
    return Padding(
      key: const ValueKey('ai-inline-error'),
      padding: const EdgeInsets.symmetric(vertical: AppTokens.space4),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.error),
          const SizedBox(width: AppTokens.space8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
          if (message == null)
            TextButton(
              key: const ValueKey('ai-open-settings'),
              onPressed: () => SettingsSheet.show(context),
              child: const Text('설정 열기'),
            ),
        ],
      ),
    );
  }
}
