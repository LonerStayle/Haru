import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_drill_list.dart';

void main() {
  Todo make({
    required String id,
    String title = 't',
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? doneAt,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: null,
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
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
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
}
