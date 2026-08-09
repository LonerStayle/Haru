import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/todo.dart';

/// 상태별 보기 필터 — 카테고리 / 상세(하위 목록) 화면 상단 칩으로 목록을 좁힌다.
///
/// 3-상태(미완료 / 진행중 / 완료) + 타입(메모) 을 하나의 축으로 합친 뷰 필터다.
/// 데이터는 건드리지 않고 **렌더 레이어에서만** 걸러낸다 — 카운트 배지는 항상 스코프
/// 전체(자손 포함) 기준이므로 "완료 3" 을 누르면 정확히 3건이 나온다.
enum TodoStatusFilter {
  /// 필터 없음 — 기존 트리(root + 드릴다운 + 완료 접기 행) 그대로.
  all('전체'),

  /// 순수 미완료 task (진행중 제외).
  undone('미완료'),

  /// 진행중(세모) task.
  inProgress('진행중'),

  /// 완료 task.
  done('완료'),

  /// note 타입 (체크 개념 없음).
  note('메모');

  const TodoStatusFilter(this.label);

  /// 칩에 표시할 한국어 라벨.
  final String label;

  /// 이 필터가 [todo] 를 목록에 남길지.
  bool matches(Todo todo) => switch (this) {
    TodoStatusFilter.all => true,
    TodoStatusFilter.undone =>
      todo.type == TodoType.task && !todo.isDone && !todo.isInProgress,
    TodoStatusFilter.inProgress =>
      todo.type == TodoType.task && todo.isInProgress,
    TodoStatusFilter.done => todo.type == TodoType.task && todo.isDone,
    TodoStatusFilter.note => todo.type == TodoType.note,
  };
}

/// 한 스코프(카테고리 / 서브트리) 안의 상태별 건수.
///
/// [all] = task + note 전부. 나머지 4개의 합과 항상 같다 (상태가 상호 배타이므로).
class TodoStatusCounts {
  const TodoStatusCounts({
    required this.all,
    required this.undone,
    required this.inProgress,
    required this.done,
    required this.note,
  });

  /// [todos] 를 한 번 순회해 5개 카운트를 동시에 센다.
  factory TodoStatusCounts.of(Iterable<Todo> todos) {
    var all = 0, undone = 0, inProgress = 0, done = 0, note = 0;
    for (final t in todos) {
      all += 1;
      if (t.type == TodoType.note) {
        note += 1;
      } else if (t.isDone) {
        done += 1;
      } else if (t.isInProgress) {
        inProgress += 1;
      } else {
        undone += 1;
      }
    }
    return TodoStatusCounts(
      all: all,
      undone: undone,
      inProgress: inProgress,
      done: done,
      note: note,
    );
  }

  final int all;
  final int undone;
  final int inProgress;
  final int done;
  final int note;

  int countOf(TodoStatusFilter filter) => switch (filter) {
    TodoStatusFilter.all => all,
    TodoStatusFilter.undone => undone,
    TodoStatusFilter.inProgress => inProgress,
    TodoStatusFilter.done => done,
    TodoStatusFilter.note => note,
  };
}

/// 상태별 보기 칩 바 — `[전체 N] [미완료 N] [진행중 N] [완료 N] [메모 N]`.
///
/// 좁은 모바일 폭에서 넘치지 않도록 [Wrap]. 메모가 0건이면 메모 칩은 생략한다
/// (기존 카테고리 헤더 동작 유지). 선택된 칩은 진한 색 + 테두리 + 굵은 글씨로,
/// 색뿐 아니라 형태로도 구분되게 했다(색각 이상 대비).
class TodoStatusFilterBar extends StatelessWidget {
  const TodoStatusFilterBar({
    super.key,
    required this.counts,
    required this.selected,
    required this.onSelected,
    required this.accent,
  });

  final TodoStatusCounts counts;
  final TodoStatusFilter selected;
  final ValueChanged<TodoStatusFilter> onSelected;

  /// 진행중 칩 강조색 — 그 스코프의 카테고리 색(세모 버튼과 같은 색 언어).
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final filter in TodoStatusFilter.values)
          // 메모가 없는 카테고리에서는 메모 칩 자체를 숨긴다.
          if (filter != TodoStatusFilter.note || counts.note > 0)
            _FilterChip(
              filter: filter,
              count: counts.countOf(filter),
              selected: filter == selected,
              base: _baseColor(filter, scheme),
              strong: _strongColor(filter, scheme),
              onTap: () => onSelected(filter),
            ),
      ],
    );
  }

  Color _baseColor(TodoStatusFilter filter, ColorScheme scheme) =>
      switch (filter) {
        TodoStatusFilter.all => scheme.onSurface.withValues(alpha: 0.6),
        TodoStatusFilter.undone => scheme.onSurface.withValues(alpha: 0.55),
        TodoStatusFilter.inProgress => accent,
        TodoStatusFilter.done => scheme.onSurface.withValues(alpha: 0.45),
        TodoStatusFilter.note => scheme.onSurface.withValues(alpha: 0.45),
      };

  /// 선택 상태 색 — 흐린 회색 칩이 선택돼도 확실히 읽히도록 대비를 끌어올린다.
  Color _strongColor(TodoStatusFilter filter, ColorScheme scheme) =>
      filter == TodoStatusFilter.inProgress
      ? accent
      : scheme.onSurface.withValues(alpha: 0.92);
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.count,
    required this.selected,
    required this.base,
    required this.strong,
    required this.onTap,
  });

  final TodoStatusFilter filter;
  final int count;
  final bool selected;
  final Color base;
  final Color strong;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? strong : base;
    return Semantics(
      button: true,
      selected: selected,
      label: '${filter.label} $count개 보기',
      child: InkWell(
        key: ValueKey('status-filter-${filter.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: AnimatedContainer(
          duration: AppTokens.motionFast,
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space4,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: selected ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(AppTokens.radiusFull),
            // 미선택도 같은 두께의 투명 테두리 — 선택 시 크기가 튀지 않게.
            border: Border.all(
              color: selected ? color : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Text(
            '${filter.label} $count',
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
