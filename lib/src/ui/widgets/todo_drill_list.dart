import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/todo.dart';
import 'dismissible_todo_tile.dart';

/// 기능 M — "평면 + 드릴다운" 한 단계 리스트 Sliver.
///
/// 인라인 ▸ 펼침(NestedTodoTreeSliver) 을 대체한다. 이 레벨의 [items] (형제 list) 만
/// 한 줄짜리로 그리되, **자식이 있는 항목은 탭 → 드릴다운**(상세 화면 push), **자식이
/// 없는 leaf 항목은 탭 → 편집**으로 분기한다.
///
/// 각 타일에서 체크 토글 / ＋하위추가 / 스와이프 삭제 / 형제 드래그 순서변경은 유지.
/// 자식 유무는 [allTodos] 에서 `parentId == item.id` 인 todo 가 1개 이상 있는지로 판정하고,
/// 그 개수를 chevron 옆 배지(자식 N) 로 표시한다.
///
/// 카테고리 화면 / 상세(TodoDetailScreen) 가 공통으로 사용한다.
///
/// **완료 접기**: 완료(체크된 task)는 활성 목록에서 분리해 "✓ 완료 N개 ▸" 접기 행 아래로
/// 모은다 (기본 접힘, 세션 단위 — 화면 재진입 시 접힘으로 초기화). 브라우징 화면에 완료가
/// 쌓여 가독성을 해치는 문제를 막는다. 오늘 화면은 이 위젯을 쓰지 않으므로(당일 완료 유지)
/// 영향받지 않는다. reorder 는 활성 항목끼리만 (완료는 재정렬 대상 아님).
class TodoDrillListSliver extends StatefulWidget {
  const TodoDrillListSliver({
    super.key,
    required this.items,
    required this.allTodos,
    required this.onDrillDown,
    required this.onEdit,
    required this.onToggle,
    required this.onAddChild,
    required this.onCopy,
    required this.onDelete,
    required this.onReorderSiblings,
    this.hiddenCountBySeries = const {},
    this.onStopRecurrence,
  });

  /// 이 레벨에서 한 줄씩 보일 형제 list (이미 dao 정렬 순서).
  final List<Todo> items;

  /// 전체 todo (자식 개수 판단용). [items] 의 각 항목에 대해 parentId 매칭으로 childCount 계산.
  final List<Todo> allTodos;

  /// 자식이 있는 폴더 항목 탭 → 상세 화면(드릴다운).
  final void Function(Todo folder) onDrillDown;

  /// 자식이 없는 leaf 항목 탭 → 편집 시트.
  final void Function(Todo leaf) onEdit;

  final void Function(Todo) onToggle;

  /// "＋ 하위 추가" — 그 항목을 부모로 자식 생성 sheet 를 연다.
  final void Function(Todo parent) onAddChild;

  /// 더보기(⋮) 메뉴 '복사' — 그 항목을 prefill 한 새 항목 시트를 연다.
  final void Function(Todo) onCopy;

  final void Function(Todo) onDelete;

  /// 같은 부모의 형제 list + (시각 순서 기준) oldIndex/newIndex 로 재정렬.
  /// 완료 접기로 활성 항목만 넘겨도 안전 — reorderSiblings 가 부분집합 min 기준 재부여.
  final void Function(List<Todo> siblings, int oldIndex, int newIndex)
  onReorderSiblings;

  /// date-repeat (FR-4) — seriesId → 숨겨진 미체크 건수. leader 타일의 묶음 배지용.
  final Map<String, int> hiddenCountBySeries;

  /// date-repeat (FR-6) — 반복 항목의 ⋮ 메뉴 '반복 중지' 콜백.
  final void Function(Todo)? onStopRecurrence;

  @override
  State<TodoDrillListSliver> createState() => _TodoDrillListSliverState();
}

class _TodoDrillListSliverState extends State<TodoDrillListSliver> {
  /// 완료 접기 섹션이 펼쳐졌는지 — 기본 접힘(완료 감춤). 세션/화면 단위(비영속).
  bool _doneExpanded = false;

  /// parentId → 직속 자식 수.
  Map<String, int> _childCounts() {
    final counts = <String, int>{};
    for (final t in widget.allTodos) {
      final pid = t.parentId;
      if (pid == null) continue;
      counts[pid] = (counts[pid] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) {
    final counts = _childCounts();

    // 완료 = 체크된 task. note(체크 개념 없음) 등은 활성 목록에 유지.
    final active = <Todo>[];
    final done = <Todo>[];
    for (final t in widget.items) {
      if (t.type == TodoType.task && t.isDone) {
        done.add(t);
      } else {
        active.add(t);
      }
    }

    Widget tile(Todo todo, {required bool reorderable, required int index}) {
      final childCount = counts[todo.id] ?? 0;
      final hasChildren = childCount > 0;
      final sid = todo.seriesId;
      final hiddenSeriesCount = sid == null
          ? 0
          : (widget.hiddenCountBySeries[sid] ?? 0);
      final tileWidget = DismissibleTodoTile(
        todo: todo,
        onToggle: () => widget.onToggle(todo),
        onDelete: () => widget.onDelete(todo),
        // 자식 있으면 드릴, 없으면 편집.
        onTap: () =>
            hasChildren ? widget.onDrillDown(todo) : widget.onEdit(todo),
        // §14 — note 도 자식(헤딩) 보유 가능 → 타입 무관하게 ＋하위 추가 노출.
        onAddChild: () => widget.onAddChild(todo),
        // 더보기(⋮) 메뉴 — 복사 / 편집(이 항목 자체) / 삭제.
        onCopy: () => widget.onCopy(todo),
        onEditItem: () => widget.onEdit(todo),
        // 드릴 가능 표시 — chevron_right + 자식 개수 배지.
        drillChildCount: hasChildren ? childCount : null,
        childCount: childCount,
        hiddenSeriesCount: hiddenSeriesCount,
        onStopRecurrence: widget.onStopRecurrence == null
            ? null
            : () => widget.onStopRecurrence!(todo),
      );
      return Padding(
        key: ValueKey('drill-node-${todo.id}'),
        padding: const EdgeInsets.only(bottom: AppTokens.space8),
        // 완료 항목은 재정렬 대상이 아니므로 drag listener 없이 그린다.
        child: reorderable
            ? ReorderableDelayedDragStartListener(
                index: index,
                child: tileWidget,
              )
            : tileWidget,
      );
    }

    final activeSliver = SliverReorderableList(
      itemCount: active.length,
      onReorder: (oldIndex, newIndex) =>
          widget.onReorderSiblings(active, oldIndex, newIndex),
      itemBuilder: (context, i) => tile(active[i], reorderable: true, index: i),
    );

    if (done.isEmpty) return activeSliver;

    return SliverMainAxisGroup(
      slivers: [
        activeSliver,
        SliverToBoxAdapter(
          child: _DrillDoneCollapseRow(
            count: done.length,
            expanded: _doneExpanded,
            onTap: () => setState(() => _doneExpanded = !_doneExpanded),
          ),
        ),
        if (_doneExpanded)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => tile(done[i], reorderable: false, index: i),
              childCount: done.length,
            ),
          ),
      ],
    );
  }
}

/// "✓ 완료 N개" 접기 행 — 낮은 강조(muted). 탭하면 이 목록의 완료 항목만 펼친다.
class _DrillDoneCollapseRow extends StatelessWidget {
  const _DrillDoneCollapseRow({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space8),
      child: InkWell(
        key: const ValueKey('drill-done-toggle'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: AppTokens.space8,
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppTokens.space8),
              Text(
                '완료 $count개',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: AppTokens.motionFast,
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
