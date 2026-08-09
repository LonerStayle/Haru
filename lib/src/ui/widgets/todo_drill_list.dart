import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/policies/todo_sort_policy.dart';
import '../../domain/todo.dart';
import 'dismissible_todo_tile.dart';
import 'todo_status_filter.dart';

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
///
/// **정렬 모드**: [sortMode] 가 [TodoSortMode.dueDate] 면 이 레벨(과 완료 섹션)을 일정
/// 빠른 순으로 다시 늘어놓는다. 화면이 계산한 순서와 드래그 결과가 어긋나므로 이때
/// 드래그 재정렬은 꺼진다 — 수동 순서로 되돌리면 다시 켜진다.
///
/// **상태별 보기**: [filter] 가 `all` 이 아니면 위 트리 렌더를 접고, [filterPool] (이
/// 스코프의 **자손 포함** 전체) 에서 조건에 맞는 항목만 **평탄한 한 겹 목록**으로 그린다.
/// 칩 카운트("완료 3")와 실제로 보이는 건수를 일치시키기 위한 선택이다 — root 만 걸러내면
/// 자손에 있는 완료 항목이 안 보여 카운트와 어긋난다. 평탄 목록에서는 소속을 알 수 있도록
/// 각 타일에 부모 경로(breadcrumb)를 얹고, 순서가 의미를 잃으므로 재정렬은 끈다.
/// 평탄 목록에도 [sortMode] 는 그대로 적용된다(일정순으로 보는 중이면 필터 결과도 일정순).
class TodoDrillListSliver extends StatefulWidget {
  const TodoDrillListSliver({
    super.key,
    required this.items,
    required this.allTodos,
    required this.onDrillDown,
    required this.onEdit,
    required this.onToggle,
    this.onToggleInProgress,
    required this.onAddChild,
    required this.onCopy,
    required this.onDelete,
    required this.onReorderSiblings,
    this.hiddenCountBySeries = const {},
    this.onStopRecurrence,
    this.sortMode = TodoSortMode.manual,
    this.filter = TodoStatusFilter.all,
    this.filterPool,
    this.breadcrumbRootId,
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

  /// 진행중(세모) 토글. null 이면 세모 버튼 미표시.
  final void Function(Todo)? onToggleInProgress;

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

  /// 목록 정렬 방식. 기본은 사용자가 드래그로 정한 수동 순서.
  final TodoSortMode sortMode;

  /// 상태별 보기 필터. `all` (기본) 이면 기존 트리 렌더 그대로.
  final TodoStatusFilter filter;

  /// [filter] 가 `all` 이 아닐 때 평탄 나열할 대상 — 이 스코프의 **자손 포함** 전체
  /// (카테고리 화면 = 그 카테고리 전체, 상세 화면 = 그 항목의 모든 자손).
  /// null 이면 [items] 만 걸러낸다.
  final List<Todo>? filterPool;

  /// 부모 경로(breadcrumb) 를 어디서 끊을지 — 이 id 위로는 올라가지 않는다.
  /// 상세 화면처럼 그 항목이 이미 화면 제목인 경우 경로에서 빼기 위한 것.
  final String? breadcrumbRootId;

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

  /// [todo] 의 부모 경로 문자열 (`상위 › 그 하위`). root 면 null.
  ///
  /// [TodoDrillListSliver.breadcrumbRootId] 에 도달하면 그 항목은 빼고 walk 를 멈춘다
  /// (이미 화면 제목인 부모를 경로에 또 쓰지 않기 위해).
  /// dangling parentId (동기화 race) 나 사이클을 만나도 거기서 멈춘다.
  String? _breadcrumbOf(Todo todo, Map<String, Todo> byId) {
    if (todo.parentId == null) return null;
    final titles = <String>[];
    final visited = <String>{todo.id};
    var current = byId[todo.parentId];
    while (current != null && current.id != widget.breadcrumbRootId) {
      if (!visited.add(current.id)) break;
      titles.insert(0, current.title);
      final pid = current.parentId;
      current = pid == null ? null : byId[pid];
    }
    return titles.isEmpty ? null : titles.join(' › ');
  }

  @override
  Widget build(BuildContext context) {
    final counts = _childCounts();

    // 완료 = 체크된 task. note(체크 개념 없음) 등은 활성 목록에 유지.
    // 정렬 모드는 활성 / 완료 각각에 적용한다 (완료가 위로 섞여 올라오지 않게).
    final ordered = TodoSortPolicy.apply(widget.items, widget.sortMode);
    final active = <Todo>[];
    final done = <Todo>[];
    for (final t in ordered) {
      if (t.type == TodoType.task && t.isDone) {
        done.add(t);
      } else {
        active.add(t);
      }
    }
    // 일정순으로 보는 동안은 드래그 재정렬을 끈다 — 드롭한 자리와 화면 순서가 어긋난다.
    final canReorder = widget.sortMode == TodoSortMode.manual;

    Widget tile(
      Todo todo, {
      required bool reorderable,
      required int index,
      String? breadcrumb,
    }) {
      final childCount = counts[todo.id] ?? 0;
      final hasChildren = childCount > 0;
      final sid = todo.seriesId;
      final hiddenSeriesCount = sid == null
          ? 0
          : (widget.hiddenCountBySeries[sid] ?? 0);
      final tileWidget = DismissibleTodoTile(
        todo: todo,
        onToggle: () => widget.onToggle(todo),
        onToggleInProgress: widget.onToggleInProgress == null
            ? null
            : () => widget.onToggleInProgress!(todo),
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
        breadcrumb: breadcrumb,
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

    // 상태별 보기 — 트리를 접고 조건에 맞는 항목만 평탄하게. 재정렬·완료접기 없음.
    // 정렬 모드는 여기서도 존중한다 (일정순으로 보는 중이면 필터 결과도 일정순).
    if (widget.filter != TodoStatusFilter.all) {
      final pool = widget.filterPool ?? widget.items;
      final matched = TodoSortPolicy.apply(
        pool.where(widget.filter.matches).toList(),
        widget.sortMode,
      );
      if (matched.isEmpty) {
        return SliverToBoxAdapter(
          child: _FilterEmptyRow(filter: widget.filter),
        );
      }
      final byId = {for (final t in widget.allTodos) t.id: t};
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => tile(
            matched[i],
            reorderable: false,
            index: i,
            breadcrumb: _breadcrumbOf(matched[i], byId),
          ),
          childCount: matched.length,
        ),
      );
    }

    final activeSliver = canReorder
        ? SliverReorderableList(
            itemCount: active.length,
            onReorder: (oldIndex, newIndex) =>
                widget.onReorderSiblings(active, oldIndex, newIndex),
            itemBuilder: (context, i) =>
                tile(active[i], reorderable: true, index: i),
          )
        : SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => tile(active[i], reorderable: false, index: i),
              childCount: active.length,
            ),
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

/// 상태별 보기에서 해당 상태가 0건일 때의 안내 행 — 목록이 빈 채로 끝나는 것보다
/// "왜 비었는지" 를 알려 준다. 다른 칩으로 옮기라는 힌트까지 한 줄.
class _FilterEmptyRow extends StatelessWidget {
  const _FilterEmptyRow({required this.filter});

  final TodoStatusFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const ValueKey('drill-filter-empty'),
      padding: const EdgeInsets.symmetric(vertical: AppTokens.space32),
      child: Column(
        children: [
          Icon(
            Icons.filter_alt_off_outlined,
            size: 28,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppTokens.space8),
          Text(
            '${filter.label} 항목이 없어요',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTokens.space4),
          Text(
            '위 칩에서 다른 상태를 눌러 보세요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
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
