import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/dismissible_todo_tile.dart';
import 'package:solo_todo/src/ui/widgets/todo_drill_list.dart';
import 'package:solo_todo/src/ui/widgets/todo_status_filter.dart';

void main() {
  Todo make({
    required String id,
    String title = 't',
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? doneAt,
    DateTime? startedAt,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: null,
    doneAt: doneAt,
    startedAt: startedAt,
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
    TodoStatusFilter filter = TodoStatusFilter.all,
    List<Todo>? filterPool,
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
                filter: filter,
                filterPool: filterPool,
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

  group('상태별 보기 필터', () {
    // root 1건 + 그 자식 2건 — "자손까지 걸러내는지" 를 보기 위한 최소 트리.
    final root = make(id: 'r', title: '루트 미완료');
    final childDone = make(
      id: 'c1',
      title: '자식 완료',
      parentId: 'r',
      doneAt: DateTime.utc(2026, 5, 30, 12),
    );
    final childNote = make(
      id: 'c2',
      title: '자식 메모',
      parentId: 'r',
      type: TodoType.note,
    );
    final all = [root, childDone, childNote];

    testWidgets('완료 필터 → root 가 아니어도 완료 자손이 보인다', (tester) async {
      await mount(
        tester,
        items: [root],
        allTodos: all,
        filter: TodoStatusFilter.done,
        filterPool: all,
      );

      expect(find.text('자식 완료'), findsOneWidget);
      // 미완료 root / 메모는 걸러진다 — 렌더된 타일은 완료 1건뿐.
      // (root 제목은 타일이 아니라 아래 테스트의 부모 경로 라벨로만 남는다.)
      expect(find.byType(DismissibleTodoTile), findsOneWidget);
      expect(find.text('자식 메모'), findsNothing);
      // 필터 뷰에서는 완료 접기 행을 쓰지 않는다 (이미 완료만 보고 있으므로).
      expect(find.byKey(const ValueKey('drill-done-toggle')), findsNothing);
    });

    testWidgets('평탄 목록의 하위 항목은 부모 경로를 함께 보여준다', (tester) async {
      await mount(
        tester,
        items: [root],
        allTodos: all,
        filter: TodoStatusFilter.done,
        filterPool: all,
      );

      final crumb = find.byKey(const ValueKey('todo-tile-breadcrumb'));
      expect(crumb, findsOneWidget);
      expect(tester.widget<Text>(crumb).data, '루트 미완료');
    });

    testWidgets('메모 필터 → note 만', (tester) async {
      await mount(
        tester,
        items: [root],
        allTodos: all,
        filter: TodoStatusFilter.note,
        filterPool: all,
      );

      expect(find.text('자식 메모'), findsOneWidget);
      expect(find.text('자식 완료'), findsNothing);
    });

    testWidgets('진행중 필터 → 진행중만 (미완료·완료 제외)', (tester) async {
      final running = make(
        id: 'p',
        title: '진행중 항목',
        startedAt: DateTime.utc(2026, 5, 30, 9),
      );
      final pool = [...all, running];
      await mount(
        tester,
        items: [root, running],
        allTodos: pool,
        filter: TodoStatusFilter.inProgress,
        filterPool: pool,
      );

      expect(find.text('진행중 항목'), findsOneWidget);
      expect(find.text('루트 미완료'), findsNothing);
      expect(find.text('자식 완료'), findsNothing);
    });

    testWidgets('해당 상태가 0건이면 안내 행', (tester) async {
      await mount(
        tester,
        items: [root],
        allTodos: [root],
        filter: TodoStatusFilter.inProgress,
        filterPool: [root],
      );

      expect(find.byKey(const ValueKey('drill-filter-empty')), findsOneWidget);
      expect(find.text('진행중 항목이 없어요'), findsOneWidget);
    });

    testWidgets('전체 필터는 기존 트리 렌더 그대로 (root 만 + 완료 접기 행)', (tester) async {
      await mount(tester, items: [root], allTodos: all, filterPool: all);

      expect(find.text('루트 미완료'), findsOneWidget);
      expect(find.text('자식 완료'), findsNothing); // 자손은 드릴다운으로만
      expect(find.byKey(const ValueKey('todo-tile-breadcrumb')), findsNothing);
    });
  });
}
