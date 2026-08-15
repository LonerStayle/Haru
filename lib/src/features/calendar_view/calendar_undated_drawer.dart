import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/todo.dart';
import 'calendar_actions.dart';
import 'calendar_providers.dart';

/// 화면 하단의 "날짜 없음" 서랍.
///
/// 아직 일정으로 옮기지 않은 할 일을 모아두고, 달력 칸으로 끌어다 놓으면 그 날짜가
/// 붙는다 — "언젠가 할 일" 을 일정으로 옮기는 동작이 이 화면에서 가장 짧아진다.
///
/// 기본은 **접힘**이고 펼침 상태는 세션 내에서만 유지한다 (영속 저장 없음).
/// 항목이 하나도 없으면 서랍 자체를 숨긴다 — 늘 비어 있는 줄이 화면 아래를
/// 차지하고 있을 이유가 없다.
class CalendarUndatedDrawer extends ConsumerStatefulWidget {
  const CalendarUndatedDrawer({super.key, this.itemWrapper});

  /// 항목을 감싸 드래그 소스로 만들기 위한 훅 (T13 에서 사용).
  final Widget Function(Todo todo, Widget tile)? itemWrapper;

  @override
  ConsumerState<CalendarUndatedDrawer> createState() =>
      _CalendarUndatedDrawerState();
}

class _CalendarUndatedDrawerState extends ConsumerState<CalendarUndatedDrawer> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = AppPlatform.isMobile;

    final todos =
        ref.watch(calendarUndatedTodosProvider).asData?.value ?? const <Todo>[];
    if (todos.isEmpty) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
            width: AppTokens.hairline,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('calendar-undated-header'),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? AppTokens.space12 : AppTokens.space24,
                vertical: AppTokens.space8,
              ),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: AppTokens.space4),
                  Text(
                    '날짜 없음',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: AppTokens.space8),
                  Text(
                    '${todos.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const Spacer(),
                  if (!_expanded)
                    Text(
                      '펼쳐서 달력으로 끌어놓기',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            // 높이를 제한하지 않으면 무날짜 항목이 수백 건일 때 서랍이 화면을
            // 통째로 밀어낸다. 안에서만 스크롤되게 상한을 둔다.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: compact ? 160 : 200),
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  compact ? AppTokens.space12 : AppTokens.space24,
                  0,
                  compact ? AppTokens.space12 : AppTokens.space24,
                  AppTokens.space12,
                ),
                itemCount: todos.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppTokens.space4),
                itemBuilder: (context, i) {
                  final t = todos[i];
                  final tile = UndatedTodoTile(todo: t);
                  return widget.itemWrapper?.call(t, tile) ?? tile;
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 서랍 안의 한 줄.
class UndatedTodoTile extends ConsumerWidget {
  const UndatedTodoTile({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('calendar-undated-tile-${todo.id}'),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        onTap: () => openCalendarEditSheet(context, ref, todo),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: AppTokens.space4,
          ),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
              width: AppTokens.hairline,
            ),
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
          ),
          child: Row(
            children: [
              // 끌 수 있다는 걸 보여주는 손잡이 글리프. 사이드바 카테고리 이동과
              // 같은 시각 언어(⠿)를 쓴다.
              Icon(
                Icons.drag_indicator,
                size: 16,
                color: scheme.onSurface.withValues(alpha: 0.3),
              ),
              const SizedBox(width: AppTokens.space4),
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: todo.category.color,
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Text(
                  todo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
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
