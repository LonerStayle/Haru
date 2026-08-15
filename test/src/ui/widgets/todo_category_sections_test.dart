import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_category_sections.dart';

/// 오늘 화면의 드래그 재정렬 — 실제 제스처로 재현한다.
///
/// 대표님 리포트: "위아래 드래그로 옮길 수 있었는데 어느새부턴가 사라진 것 같다",
/// "다른 항목 쪽으로 끌었다가 원래 자리로 원상복귀된다".
/// 오늘 화면은 카테고리별로 **독립된 SliverReorderableList** 로 쪼개져 있어
/// 섹션 경계를 넘는 드래그가 성립하지 않는다 — 그 경계를 여기서 못박는다.
void main() {
  Todo make({
    required String id,
    required String title,
    required Category category,
    int sortOrder = 0,
  }) => Todo(
    id: id,
    title: title,
    category: category,
    dueAt: DateTime(2026, 8, 15),
    doneAt: null,
    createdAt: DateTime.utc(2026, 8, 15),
    updatedAt: DateTime.utc(2026, 8, 15),
    calendarEventId: null,
    sortOrder: sortOrder,
  );

  /// 재정렬 콜백이 받은 (카테고리 항목들, old, new).
  late List<(List<Todo>, int, int)> calls;

  Future<void> mount(WidgetTester tester, List<Todo> roots) async {
    calls = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.mobileLight(),
        home: Scaffold(
          body: CustomScrollView(
            slivers: todayCategorySectionSlivers(
              roots: roots,
              allTodos: roots,
              groups: const [],
              showGroupLabel: false,
              onDrillDown: (_) {},
              onEdit: (_) {},
              onToggle: (_) {},
              onAddChild: (_) {},
              onMove: (_) {},
              onCopy: (_) {},
              onDelete: (_) {},
              onReorderSiblings: (items, oldIndex, newIndex) =>
                  calls.add((items, oldIndex, newIndex)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 롱프레스(ReorderableDelayedDragStartListener) 후 [dy] 만큼 끌어 놓는다.
  Future<void> dragTile(WidgetTester tester, String title, double dy) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(title)),
    );
    // 지연 드래그 인식기가 잡을 때까지 눌러 둔다.
    await tester.pump(const Duration(milliseconds: 600));
    // 한 번에 이동하면 인식기가 놓치므로 잘게 나눠 민다.
    final step = dy / 10;
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, step));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('같은 카테고리 섹션 안에서는 위아래 드래그가 동작한다', (tester) async {
    await mount(tester, [
      make(id: 'a1', title: '회사 하나', category: Category.work),
      make(id: 'a2', title: '회사 둘', category: Category.work, sortOrder: 1),
    ]);

    final gap =
        tester.getCenter(find.text('회사 둘')).dy -
        tester.getCenter(find.text('회사 하나')).dy;
    await dragTile(tester, '회사 하나', gap + 8);

    expect(calls, isNotEmpty, reason: '섹션 안 드래그는 재정렬로 이어져야 한다');
    expect(calls.single.$1.map((t) => t.id), ['a1', 'a2']);
    expect(calls.single.$2, 0);
  });

  testWidgets('다른 카테고리 섹션으로 끌어도 그 카테고리로는 못 넘어간다 (제자리 복귀)', (tester) async {
    await mount(tester, [
      make(id: 'a1', title: '회사 하나', category: Category.work),
      make(id: 'b1', title: '일상 하나', category: Category.daily),
    ]);

    final gap =
        tester.getCenter(find.text('일상 하나')).dy -
        tester.getCenter(find.text('회사 하나')).dy;
    await dragTile(tester, '회사 하나', gap + 40);

    // 섹션이 독립 리스트라 목적지 섹션은 드롭을 받지 못한다. 재정렬이 일어나더라도
    // 그 대상은 언제나 출발 섹션(회사)의 1개짜리 목록 — 카테고리는 절대 안 바뀐다.
    for (final c in calls) {
      expect(
        c.$1.map((t) => t.category.id).toSet(),
        {'work'},
        reason: '드롭 대상이 다른 카테고리 섹션으로 넘어가면 안 된다 (현행 한계)',
      );
    }
    expect(find.text('회사 하나'), findsOneWidget, reason: '항목은 원래 섹션에 그대로 남는다');
  });
}
