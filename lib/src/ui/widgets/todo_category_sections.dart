import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../../domain/todo.dart';
import 'dismissible_todo_tile.dart';

/// 오늘 화면 전용 — root todo 들을 **카테고리별 섹션**으로 묶어 그리는 sliver 목록.
///
/// 각 섹션은 [_CategorySectionHeader] (카테고리 아이콘 + 라벨 + 소속 그룹 라벨 +
/// 완료 진척) 와, 그 카테고리에 속한 항목들의 독립 [SliverReorderableList] 로 구성된다.
/// 섹션별 독립 재정렬이므로 [onReorderSiblings] 에는 그 카테고리 항목 리스트만 넘어가고,
/// `reorderSiblings` 가 부분집합 min 기준으로 sortOrder 를 재부여한다(타 카테고리 불변).
///
/// 자식 유무·드릴다운·＋하위추가·스와이프 삭제·체크 토글은 [TodoDrillListSliver] 와 동일
/// 규칙을 그대로 유지한다 — 단지 평면 리스트를 카테고리 섹션으로 묶었을 뿐이다.
///
/// 반환값은 `CustomScrollView.slivers` 에 `...spread` 로 펼쳐 넣는다.
List<Widget> todayCategorySectionSlivers({
  required List<Todo> roots,
  required List<Todo> allTodos,
  required List<Group> groups,
  required bool showGroupLabel,
  required void Function(Todo folder) onDrillDown,
  required void Function(Todo leaf) onEdit,
  required void Function(Todo) onToggle,
  void Function(Todo)? onToggleInProgress,
  required void Function(Todo parent) onAddChild,
  required void Function(Todo) onCopy,
  required void Function(Todo) onDelete,
  required void Function(List<Todo> siblings, int oldIndex, int newIndex)
  onReorderSiblings,
  Map<String, int> hiddenCountBySeries = const {},
  void Function(Todo)? onStopRecurrence,
}) {
  // parentId → 직속 자식 수 (드릴 배지 / 편집 분기 판정용).
  final childCounts = <String, int>{};
  for (final t in allTodos) {
    final pid = t.parentId;
    if (pid == null) continue;
    childCounts[pid] = (childCounts[pid] ?? 0) + 1;
  }

  // 카테고리별 묶음 — roots 순서(=dao sortOrder)를 보존한다.
  final orderedCatIds = <String>[];
  final byCat = <String, List<Todo>>{};
  final catOf = <String, Category>{};
  for (final t in roots) {
    final cid = t.category.id;
    if (!byCat.containsKey(cid)) {
      orderedCatIds.add(cid);
      byCat[cid] = [];
    }
    byCat[cid]!.add(t);
    catOf[cid] = t.category;
  }

  // 섹션 정렬: (그룹 sortOrder, 카테고리 sortOrder). 미분류(groupId==null)는 맨 위.
  final groupSort = {for (final g in groups) g.id: g.sortOrder};
  final groupLabel = {for (final g in groups) g.id: g.label};
  orderedCatIds.sort((a, b) {
    final ca = catOf[a]!, cb = catOf[b]!;
    final ga = ca.groupId == null ? -1 : (groupSort[ca.groupId] ?? 1 << 20);
    final gb = cb.groupId == null ? -1 : (groupSort[cb.groupId] ?? 1 << 20);
    if (ga != gb) return ga.compareTo(gb);
    if (ca.sortOrder != cb.sortOrder) {
      return ca.sortOrder.compareTo(cb.sortOrder);
    }
    return ca.label.compareTo(cb.label);
  });

  final slivers = <Widget>[];
  for (var s = 0; s < orderedCatIds.length; s++) {
    final cid = orderedCatIds[s];
    final cat = catOf[cid]!;
    final items = byCat[cid]!;
    final tasks = items.where((t) => t.type == TodoType.task);
    final total = tasks.length;
    final done = tasks.where((t) => t.isDone).length;
    final gLabel = (showGroupLabel && cat.groupId != null)
        ? groupLabel[cat.groupId]
        : null;

    slivers.add(
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          AppTokens.space24,
          s == 0 ? AppTokens.space8 : AppTokens.space24,
          AppTokens.space24,
          AppTokens.space12,
        ),
        sliver: SliverToBoxAdapter(
          child: _CategorySectionHeader(
            category: cat,
            groupLabel: gLabel,
            done: done,
            total: total,
          ),
        ),
      ),
    );

    slivers.add(
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.space24),
        sliver: SliverReorderableList(
          itemCount: items.length,
          onReorder: (oldIndex, newIndex) =>
              onReorderSiblings(items, oldIndex, newIndex),
          itemBuilder: (context, i) {
            final todo = items[i];
            final childCount = childCounts[todo.id] ?? 0;
            final hasChildren = childCount > 0;
            return Padding(
              key: ValueKey('drill-node-${todo.id}'),
              padding: const EdgeInsets.only(bottom: AppTokens.space8),
              child: ReorderableDelayedDragStartListener(
                index: i,
                child: DismissibleTodoTile(
                  todo: todo,
                  onToggle: () => onToggle(todo),
                  onToggleInProgress: onToggleInProgress == null
                      ? null
                      : () => onToggleInProgress(todo),
                  onDelete: () => onDelete(todo),
                  onTap: () => hasChildren ? onDrillDown(todo) : onEdit(todo),
                  // §14 — note 도 자식(헤딩) 보유 가능 → 타입 무관 ＋하위 추가.
                  onAddChild: () => onAddChild(todo),
                  // 더보기(⋮) 메뉴 — 복사 / 편집(이 항목 자체) / 삭제.
                  onCopy: () => onCopy(todo),
                  onEditItem: () => onEdit(todo),
                  drillChildCount: hasChildren ? childCount : null,
                  childCount: childCount,
                  hiddenSeriesCount: todo.seriesId == null
                      ? 0
                      : (hiddenCountBySeries[todo.seriesId] ?? 0),
                  onStopRecurrence: onStopRecurrence == null
                      ? null
                      : () => onStopRecurrence(todo),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  return slivers;
}

/// 카테고리 섹션 헤더 — 아이콘 배지 + 카테고리 라벨 + (선택) 그룹 라벨 + 진척.
class _CategorySectionHeader extends StatelessWidget {
  const _CategorySectionHeader({
    required this.category,
    required this.groupLabel,
    required this.done,
    required this.total,
  });

  final Category category;
  final String? groupLabel;
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = category.color;
    final ratio = total == 0 ? 0.0 : done / total;
    final allDone = total > 0 && done >= total;

    return Row(
      children: [
        // 카테고리 아이콘 배지 — soft tint 배경 + 카테고리 색 아이콘.
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
          ),
          child: Icon(category.icon, size: 17, color: color),
        ),
        const SizedBox(width: AppTokens.space12),
        Flexible(
          child: Text(
            category.label,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (groupLabel != null) ...[
          const SizedBox(width: AppTokens.space8),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.space8,
              vertical: AppTokens.space2,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            ),
            child: Text(
              groupLabel!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.75),
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const Spacer(),
        // 진척 — task 가 있을 때만. mini 바 + 분수.
        if (total > 0) ...[
          Container(
            width: 40,
            height: 5,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.space8),
          Text(
            '$done/$total',
            style: theme.textTheme.labelMedium?.copyWith(
              color: allDone ? color : scheme.onSurface.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
