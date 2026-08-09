import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_drill_list.dart';

void main() {
  Todo make({
    required String id,
    String title = 't',
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? doneAt,
    DateTime? dueAt,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: dueAt,
    doneAt: doneAt,
    createdAt: DateTime.utc(2026, 5, 30),
    updatedAt: DateTime.utc(2026, 5, 30),
    calendarEventId: null,
    parentId: parentId,
    type: type,
  );

  Future<void> mount(
    WidgetTester tester, {
    required List<Todo> items,
    required List<Todo> allTodos,
    void Function(Todo)? onDrillDown,
    void Function(Todo)? onEdit,
    TodoSortMode sortMode = TodoSortMode.manual,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              TodoDrillListSliver(
                items: items,
                allTodos: allTodos,
                onDrillDown: onDrillDown ?? (_) {},
                onEdit: onEdit ?? (_) {},
                onToggle: (_) {},
                onAddChild: (_) {},
                onCopy: (_) {},
                onDelete: (_) {},
                onReorderSiblings: (_, _, _) {},
                sortMode: sortMode,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 화면에 그려진 순서대로 제목을 수집 (세로 위치 기준).
  List<String> visibleTitles(WidgetTester tester, List<String> candidates) {
    final found = <(double, String)>[];
    for (final title in candidates) {
      final finder = find.text(title);
      if (finder.evaluate().isEmpty) continue;
      found.add((tester.getTopLeft(finder).dy, title));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final e in found) e.$2];
  }

  testWidgets('자식 있는 항목 탭 → onDrillDown 호출 (onEdit 아님)', (tester) async {
    final parent = make(id: 'p', title: '폴더');
    final child = make(id: 'c', parentId: 'p');
    Todo? drilled;
    Todo? edited;
    await mount(
      tester,
      items: [parent],
      allTodos: [parent, child],
      onDrillDown: (t) => drilled = t,
      onEdit: (t) => edited = t,
    );

    await tester.tap(find.text('폴더'));
    await tester.pump();

    expect(drilled?.id, 'p');
    expect(edited, isNull);
    // 드릴 배지 노출.
    expect(find.byKey(const ValueKey('todo-tile-drill-p')), findsOneWidget);
    expect(find.text('하위 1'), findsOneWidget);
  });

  testWidgets('leaf(자식 없음) 탭 → onEdit 호출 (onDrillDown 아님)', (tester) async {
    final leaf = make(id: 'l', title: '단일');
    Todo? drilled;
    Todo? edited;
    await mount(
      tester,
      items: [leaf],
      allTodos: [leaf],
      onDrillDown: (t) => drilled = t,
      onEdit: (t) => edited = t,
    );

    await tester.tap(find.text('단일'));
    await tester.pump();

    expect(edited?.id, 'l');
    expect(drilled, isNull);
    expect(find.byKey(const ValueKey('todo-tile-drill-l')), findsNothing);
  });

  testWidgets('§14 — note 항목도 ＋하위 추가 버튼 노출 + 콜백 호출', (tester) async {
    final note = make(id: 'm', title: '섹션 메모', type: TodoType.note);
    Todo? added;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              TodoDrillListSliver(
                items: [note],
                allTodos: [note],
                onDrillDown: (_) {},
                onEdit: (_) {},
                onToggle: (_) {},
                onAddChild: (t) => added = t,
                onCopy: (_) {},
                onDelete: (_) {},
                onReorderSiblings: (_, _, _) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final addBtn = find.byKey(const ValueKey('todo-tile-add-child-m'));
    expect(addBtn, findsOneWidget);
    await tester.tap(addBtn);
    await tester.pump();
    expect(added?.id, 'm');
  });

  testWidgets('완료(체크된 task)는 기본 접힘 + "완료 N개" 행 → 탭하면 펼침', (tester) async {
    final active = make(id: 'a', title: '진행중');
    final done = make(
      id: 'd',
      title: '끝난 일',
      doneAt: DateTime.utc(2026, 5, 30, 12),
    );
    await mount(tester, items: [active, done], allTodos: [active, done]);

    // 미완료는 노출, 완료는 기본 접힘.
    expect(find.text('진행중'), findsOneWidget);
    expect(find.text('끝난 일'), findsNothing);
    expect(find.text('완료 1개'), findsOneWidget);

    // 접기 행 탭 → 완료 노출.
    await tester.tap(find.byKey(const ValueKey('drill-done-toggle')));
    await tester.pump();
    expect(find.text('끝난 일'), findsOneWidget);

    // 다시 탭 → 접힘.
    await tester.tap(find.byKey(const ValueKey('drill-done-toggle')));
    await tester.pump();
    expect(find.text('끝난 일'), findsNothing);
  });

  testWidgets('완료가 없으면 "완료 N개" 접기 행이 없다', (tester) async {
    final a = make(id: 'a', title: '진행중 A');
    final b = make(id: 'b', title: '진행중 B');
    await mount(tester, items: [a, b], allTodos: [a, b]);

    expect(find.text('진행중 A'), findsOneWidget);
    expect(find.text('진행중 B'), findsOneWidget);
    expect(find.byKey(const ValueKey('drill-done-toggle')), findsNothing);
  });

  testWidgets('일정순 모드 — 일정이 빠른 순으로 그려지고 날짜 없는 항목은 맨 뒤', (tester) async {
    final late_ = make(
      id: 'l',
      title: '늦은 일',
      dueAt: DateTime.utc(2026, 8, 20, 9),
    );
    final none = make(id: 'n', title: '날짜 없는 일');
    final early = make(
      id: 'e',
      title: '빠른 일',
      dueAt: DateTime.utc(2026, 8, 3, 9),
    );
    final items = [late_, none, early];

    // 수동 모드는 들어온 순서 그대로.
    await mount(tester, items: items, allTodos: items);
    expect(visibleTitles(tester, ['늦은 일', '날짜 없는 일', '빠른 일']), [
      '늦은 일',
      '날짜 없는 일',
      '빠른 일',
    ]);

    // 일정순 모드는 dueAt 오름차순 + 날짜 없는 항목 뒤로.
    await mount(
      tester,
      items: items,
      allTodos: items,
      sortMode: TodoSortMode.dueDate,
    );
    expect(visibleTitles(tester, ['늦은 일', '날짜 없는 일', '빠른 일']), [
      '빠른 일',
      '늦은 일',
      '날짜 없는 일',
    ]);
  });

  testWidgets('일정순 모드에서는 드래그 재정렬이 꺼진다', (tester) async {
    final a = make(id: 'a', title: 'A', dueAt: DateTime.utc(2026, 8, 3));
    final b = make(id: 'b', title: 'B', dueAt: DateTime.utc(2026, 8, 5));

    await mount(tester, items: [a, b], allTodos: [a, b]);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNWidgets(2));

    await mount(
      tester,
      items: [a, b],
      allTodos: [a, b],
      sortMode: TodoSortMode.dueDate,
    );
    expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
    // 항목 자체는 그대로 보인다.
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('일정순 모드 — 완료 섹션도 일정순으로 펼쳐진다', (tester) async {
    final doneLate = make(
      id: 'dl',
      title: '늦게 끝낼 일',
      dueAt: DateTime.utc(2026, 8, 20),
      doneAt: DateTime.utc(2026, 8, 21),
    );
    final doneEarly = make(
      id: 'de',
      title: '먼저 끝낼 일',
      dueAt: DateTime.utc(2026, 8, 2),
      doneAt: DateTime.utc(2026, 8, 3),
    );
    final active = make(
      id: 'a',
      title: '남은 일',
      dueAt: DateTime.utc(2026, 8, 5),
    );
    final items = [doneLate, active, doneEarly];

    await mount(
      tester,
      items: items,
      allTodos: items,
      sortMode: TodoSortMode.dueDate,
    );

    // 완료는 접힌 채로 활성 항목만 보인다.
    expect(find.text('남은 일'), findsOneWidget);
    expect(find.text('완료 2개'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('drill-done-toggle')));
    await tester.pump();

    expect(visibleTitles(tester, ['먼저 끝낼 일', '늦게 끝낼 일']), [
      '먼저 끝낼 일',
      '늦게 끝낼 일',
    ]);
  });
}
