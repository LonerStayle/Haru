import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/ui/widgets/todo_category_sections.dart';

/// 오늘 화면의 드래그 재정렬 — 실제 제스처로 검증한다.
///
/// 대표님 리포트: "위아래 드래그로 옮길 수 있었는데 어느새부턴가 사라진 것 같다",
/// "다른 항목 쪽으로 끌었다가 원래 자리로 원상복귀된다".
/// 원인은 카테고리별로 쪼개진 독립 리스트라 섹션 경계를 넘는 드롭을 받을 곳이
/// 없었던 것 — 한 리스트로 합쳐 섹션 간 이동까지 되게 했고, 여기서 그걸 못박는다.
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

  /// 같은 섹션 재정렬 콜백이 받은 (항목들, old, new).
  late List<(List<Todo>, int, int)> reorders;

  /// 섹션 간 이동 콜백이 받은 (항목, 대상 카테고리, 대상 목록, 삽입 위치).
  late List<(Todo, Category, List<Todo>, int)> moves;

  Future<void> mount(WidgetTester tester, List<Todo> roots) async {
    reorders = [];
    moves = [];
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
                  reorders.add((items, oldIndex, newIndex)),
              onMoveToCategory: (item, target, targetItems, insertIndex) =>
                  moves.add((item, target, targetItems, insertIndex)),
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

  double gapBetween(WidgetTester tester, String from, String to) =>
      tester.getCenter(find.text(to)).dy - tester.getCenter(find.text(from)).dy;

  testWidgets('같은 카테고리 섹션 안에서는 순서만 바뀐다', (tester) async {
    await mount(tester, [
      make(id: 'a1', title: '회사 하나', category: Category.work),
      make(id: 'a2', title: '회사 둘', category: Category.work, sortOrder: 1),
    ]);

    await dragTile(tester, '회사 하나', gapBetween(tester, '회사 하나', '회사 둘') + 8);

    expect(reorders, isNotEmpty, reason: '섹션 안 드래그는 재정렬로 이어져야 한다');
    expect(reorders.last.$1.map((t) => t.id), ['a1', 'a2']);
    expect(reorders.last.$2, 0);
    expect(moves, isEmpty, reason: '같은 카테고리면 이동이 아니다');
  });

  testWidgets('다른 카테고리 섹션에 놓으면 그 카테고리로 이동한다', (tester) async {
    await mount(tester, [
      make(id: 'a1', title: '회사 하나', category: Category.work),
      make(id: 'b1', title: '일상 하나', category: Category.daily),
    ]);

    await dragTile(tester, '회사 하나', gapBetween(tester, '회사 하나', '일상 하나') + 40);

    expect(moves, isNotEmpty, reason: '섹션 경계를 넘는 드롭이 이동으로 이어져야 한다');
    final (item, target, targetItems, _) = moves.last;
    expect(item.id, 'a1');
    expect(target.id, 'daily');
    expect(targetItems.map((t) => t.id), ['b1']);
    expect(reorders, isEmpty, reason: '카테고리가 바뀌면 단순 재정렬이 아니다');
  });

  testWidgets('헤더는 드래그 대상이 아니다', (tester) async {
    await mount(tester, [
      make(id: 'a1', title: '회사 하나', category: Category.work),
      make(id: 'b1', title: '일상 하나', category: Category.daily),
    ]);

    await dragTile(tester, Category.work.label, 200);

    expect(reorders, isEmpty);
    expect(moves, isEmpty);
  });
}
