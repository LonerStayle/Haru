import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/ui_prefs.dart';
import '../../data/providers.dart';
import '../../domain/policies/monthly_repeat_policy.dart';
import '../../domain/recurrence.dart';
import '../../domain/todo.dart';
import '../add_todo/add_todo_controller.dart';
import '../category/categories_controller.dart';
import '../outline/tree_providers.dart';

/// 할 일 id → "매월 반복으로 만들기" 제안 ([MonthlyRepeatPolicy]).
final monthlyRepeatSuggestionsProvider =
    Provider<Map<String, MonthlyRepeatSuggestion>>((ref) {
      final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
      final found = MonthlyRepeatPolicy.detect(all);
      // 대부분은 여기서 끝난다 — 카테고리 목록은 제안 거리가 있을 때만 본다.
      if (found.isEmpty) return found;
      final active = ref.watch(activeCategoriesProvider).asData?.value;
      if (active == null) return const {};
      // 보관된 카테고리의 항목엔 제안하지 않는다 — 반복이 다른 카테고리에 생긴다.
      final ids = {for (final c in active) c.id};
      return {
        for (final t in all)
          if (found[t.id] != null && ids.contains(t.category.id))
            t.id: found[t.id]!,
      };
    });

/// "그만 보기" 한 묶음 키 — 기기별.
const monthlyRepeatDismissedKey = 'suggest.monthlyRepeatDismissed';

/// 상세 화면의 제안 카드. 누르면 반복이 미리 채워진 새 할 일 시트가 열리고,
/// 저장은 대표님이 시트에서 누를 때만 된다. 반복으로 만들면 묶음에 마스터가 생겨
/// 카드는 저절로 사라진다.
class MonthlyRepeatSuggestionCard extends ConsumerWidget {
  const MonthlyRepeatSuggestionCard({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestion = ref.watch(monthlyRepeatSuggestionsProvider)[todo.id];
    final dismissed = ref.watch(
      persistedIdSetProvider(monthlyRepeatDismissedKey),
    );
    if (suggestion == null || dismissed.contains(suggestion.key)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final accent = todo.category.color;
    return Container(
      key: const ValueKey('detail-monthly-suggestion'),
      margin: const EdgeInsets.only(top: AppTokens.space8),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space8,
        AppTokens.space4,
        AppTokens.space4,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.repeat_rounded, size: 18, color: accent),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Text(
                  '${suggestion.monthCount}개월째 매달 직접 추가하고 있어요',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 26,
              top: AppTokens.space4,
              right: AppTokens.space8,
            ),
            child: Text(
              '"${suggestion.title}" 을(를) 매월 ${suggestion.dayOfMonth}일 반복으로 '
              '만들면 달마다 알아서 생겨요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('monthly-suggestion-dismiss'),
                onPressed: () => ref
                    .read(
                      persistedIdSetProvider(
                        monthlyRepeatDismissedKey,
                      ).notifier,
                    )
                    .set(suggestion.key, true),
                child: const Text('그만 보기'),
              ),
              FilledButton.tonal(
                key: const ValueKey('monthly-suggestion-create'),
                onPressed: () => showNewTodoSheet(
                  context,
                  ref,
                  initialCategory: todo.category,
                  initialTitle: suggestion.title,
                  initialDueAt: MonthlyRepeatPolicy.firstDate(
                    suggestion,
                    ref.read(nowProvider)(),
                  ),
                  initialRecurrence: RecurrenceFreq.monthly,
                ),
                child: const Text('매월 반복 만들기'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
