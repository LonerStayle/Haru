import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/policies/todo_sort_policy.dart';

/// 정렬 토글의 공통 문구 — 버튼(라벨형)과 AppBar(아이콘형)가 같은 말을 쓰도록 한 곳에 둔다.
const String _sortLabel = '일정순';
String _sortTooltip(TodoSortMode mode) =>
    mode == TodoSortMode.dueDate ? '내가 정한 순서로 보기' : '일정이 빠른 순으로 보기';

/// 목록 정렬 토글 버튼 (라벨형) — 카테고리 화면 헤더용.
///
/// **스위치처럼** 읽히도록 라벨은 항상 "일정순" 고정이고, 켜짐/꺼짐을 색으로 구분한다.
/// 켜짐 = 카테고리색으로 채워짐, 꺼짐 = 옅은 테두리 + 낮은 강조.
class SortModeButton extends StatelessWidget {
  const SortModeButton({
    super.key,
    required this.mode,
    required this.accent,
    required this.onPressed,
  });

  final TodoSortMode mode;

  /// 켜짐 상태 강조색 (카테고리색).
  final Color accent;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = mode == TodoSortMode.dueDate;
    final fg = on ? accent : scheme.onSurfaceVariant;

    return Tooltip(
      message: _sortTooltip(mode),
      child: Semantics(
        button: true,
        toggled: on,
        label: '$_sortLabel 정렬',
        child: Material(
          color: on ? accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          child: InkWell(
            key: const ValueKey('sort-mode-button'),
            onTap: onPressed,
            borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            child: Container(
              // 터치 타깃 확보 (모바일 최소 높이).
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                border: Border.all(
                  color: on
                      ? accent.withValues(alpha: 0.55)
                      : scheme.outlineVariant,
                  width: on ? 1.4 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.schedule_rounded, size: 18, color: fg),
                  const SizedBox(width: AppTokens.space4),
                  Text(
                    _sortLabel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 같은 토글의 AppBar 아이콘 버전 — 하위 상세(체크리스트) 화면용.
/// 상태는 [SortModeButton] 과 공유되므로, 어느 쪽에서 눌러도 같은 설정이 바뀐다.
class SortModeIconButton extends StatelessWidget {
  const SortModeIconButton({
    super.key,
    required this.mode,
    required this.accent,
    required this.onPressed,
  });

  final TodoSortMode mode;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final on = mode == TodoSortMode.dueDate;
    return IconButton(
      key: const ValueKey('sort-mode-icon-button'),
      tooltip: _sortTooltip(mode),
      isSelected: on,
      icon: Icon(
        Icons.schedule_rounded,
        color: on ? accent : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: onPressed,
    );
  }
}
