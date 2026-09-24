import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/todo_actions/todo_actions_controller.dart';
import 'package:solo_todo/src/features/todo_actions/toggle_with_undo.dart';
import 'package:solo_todo/src/ui/widgets/dismissible_todo_tile.dart';
import 'package:solo_todo/src/ui/widgets/todo_category_sections.dart';
import 'package:solo_todo/src/ui/widgets/todo_tile.dart';
import 'package:solo_todo/src/ui/widgets/undo_snackbar.dart';

/// UX Phase 1 — "체크 하나 + 나머지 숨김" (대표님 결정 2026-09-25).
void main() {
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  Todo make({DateTime? doneAt, DateTime? startedAt}) => Todo(
    id: 'a',
    title: '보고서 쓰기',
    category: Category.work,
    dueAt: null,
    doneAt: doneAt,
    startedAt: startedAt,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
  );

  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.mobileLight(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 600, child: child),
        ),
      ),
    ),
  );

  group('체크 하나 (○/◐/●)', () {
    testWidgets('진행중이면 반채움 ◐', (tester) async {
      await mount(
        tester,
        TodoTile(
          todo: make(startedAt: DateTime.utc(2026, 5, 27, 10)),
          onToggle: () {},
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('todo-tile-check')),
          matching: find.byKey(const ValueKey('todo-status-check-half')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('이월 항목은 메타 줄에 "이월"', (tester) async {
      await mount(tester, TodoTile(todo: make(), isCarriedOver: true));
      expect(
        find.byKey(const ValueKey('todo-tile-carryover-label')),
        findsOneWidget,
      );
    });
  });

  group('데스크탑 — hover 버튼 + 우클릭 메뉴', () {
    setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.desktop);

    double hoverOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('todo-tile-hover-actions')),
        )
        .opacity;

    testWidgets('마우스를 올려야 △ ↳ ⋮ 가 보인다', (tester) async {
      await mount(
        tester,
        TodoTile(
          todo: make(),
          onToggle: () {},
          onToggleInProgress: () {},
          onAddChild: () {},
          onDelete: () {},
        ),
      );
      expect(hoverOpacity(tester), 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('보고서 쓰기')));
      await tester.pumpAndSettle();
      expect(hoverOpacity(tester), 1);

      await mouse.moveTo(const Offset(1, 590));
      await tester.pumpAndSettle();
      expect(hoverOpacity(tester), 0);
    });

    testWidgets('우클릭 → 전체 메뉴(진행중·하위 추가 포함), 고르면 실행', (tester) async {
      var progress = 0;
      var tapped = 0;
      await mount(
        tester,
        TodoTile(
          todo: make(),
          onToggle: () {},
          onTap: () => tapped++,
          onToggleInProgress: () => progress++,
          onAddChild: () {},
          onMove: () {},
          onDelete: () {},
        ),
      );
      await tester.tap(
        find.text('보고서 쓰기'),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.text('진행중으로'), findsOneWidget);
      expect(find.text('하위 추가'), findsWidgets);
      expect(find.text('이동'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);

      await tester.tap(find.text('진행중으로'));
      await tester.pumpAndSettle();
      expect(progress, 1);
      expect(tapped, 0, reason: '우클릭은 편집 시트를 열지 않는다');
    });
  });

  group('폰 — 길게 눌렀다 떼면 메뉴, 움직이면 아님', () {
    setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.mobile);

    Widget tile({
      required VoidCallback onTap,
      required VoidCallback onProgress,
    }) => TodoTile(
      todo: make(),
      onToggle: () {},
      onTap: onTap,
      onToggleInProgress: onProgress,
      onCopy: () {},
      onDelete: () {},
    );

    testWidgets('길게 눌렀다 떼면 메뉴 시트 — 편집 시트(탭)는 열리지 않는다', (tester) async {
      var tapped = 0;
      var progress = 0;
      await mount(
        tester,
        tile(onTap: () => tapped++, onProgress: () => progress++),
      );

      final g = await tester.startGesture(
        tester.getCenter(find.text('보고서 쓰기')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.up();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('todo-tile-menu-sheet')),
        findsOneWidget,
      );
      expect(tapped, 0);

      await tester.tap(
        find.byKey(const ValueKey('todo-tile-sheet-inProgress')),
      );
      await tester.pumpAndSettle();
      expect(progress, 1);
      expect(find.byKey(const ValueKey('todo-tile-menu-sheet')), findsNothing);
    });

    testWidgets('짧게 탭하면 메뉴 없이 탭(편집)', (tester) async {
      var tapped = 0;
      await mount(tester, tile(onTap: () => tapped++, onProgress: () {}));
      await tester.tap(find.text('보고서 쓰기'));
      await tester.pumpAndSettle();
      expect(tapped, 1);
      expect(find.byKey(const ValueKey('todo-tile-menu-sheet')), findsNothing);
    });

    testWidgets('길게 누른 채 움직이면(순서 이동) 메뉴가 뜨지 않는다', (tester) async {
      await mount(tester, tile(onTap: () {}, onProgress: () {}));
      final start = tester.getCenter(find.text('보고서 쓰기'));
      final g = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await g.moveTo(start + const Offset(0, 60));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('todo-tile-menu-sheet')), findsNothing);
    });

    testWidgets('오른쪽 스와이프 = 완료, 카드는 제자리 (삭제 아님)', (tester) async {
      var toggled = 0;
      var deleted = 0;
      await mount(
        tester,
        DismissibleTodoTile(
          todo: make(),
          onToggle: () => toggled++,
          onDelete: () => deleted++,
        ),
      );
      await tester.fling(find.text('보고서 쓰기'), const Offset(400, 0), 1500);
      await tester.pumpAndSettle();
      expect(toggled, 1);
      expect(deleted, 0);
      expect(find.text('보고서 쓰기'), findsOneWidget);
    });
  });

  group('폰 — 순서 이동 목록 안에서도 (오늘 화면 섹션)', () {
    setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.mobile);

    Todo item(String id, String title, int order) => Todo(
      id: id,
      title: title,
      category: Category.work,
      dueAt: null,
      doneAt: null,
      createdAt: DateTime.utc(2026, 5, 27, 9),
      updatedAt: DateTime.utc(2026, 5, 27, 9),
      calendarEventId: null,
      sortOrder: order,
    );

    Future<List<int>> mountList(WidgetTester tester) async {
      final reorders = <int>[];
      final roots = [
        item('a', '첫째', 0),
        item('b', '둘째', 1),
        item('c', '셋째', 2),
      ];
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
                onToggleInProgress: (_) {},
                onAddChild: (_) {},
                onMove: (_) {},
                onCopy: (_) {},
                onDelete: (_) {},
                onReorderSiblings: (_, o, n) => reorders.addAll([o, n]),
                onMoveToCategory: (_, _, _, _) {},
              ),
            ),
          ),
        ),
      );
      return reorders;
    }

    testWidgets('길게 눌렀다 제자리에서 떼면 메뉴, 순서는 그대로', (tester) async {
      final reorders = await mountList(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('첫째')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      await g.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('todo-tile-menu-sheet')),
        findsOneWidget,
      );
      expect(reorders, isEmpty);
    });

    testWidgets('길게 누른 채 끌면 순서 이동, 메뉴 없음', (tester) async {
      final reorders = await mountList(tester);
      final start = tester.getCenter(find.text('첫째'));
      final g = await tester.startGesture(start);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(start + Offset(0, 20.0 * i));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('todo-tile-menu-sheet')), findsNothing);
      expect(reorders, isNotEmpty);
    });
  });

  group('체크 되돌리기', () {
    testWidgets('완료하면 스낵바, 되돌리면 체크 전 상태(진행중)로', (tester) async {
      final actions = _FakeActions();
      final inProgress = make(startedAt: DateTime.utc(2026, 5, 27, 10));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => toggleWithUndo(context, actions, inProgress),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('check'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('"보고서 쓰기" 완료'), findsOneWidget);
      await tester.tap(find.text('되돌리기'));
      await tester.pump();
      // 체크 전 상태(진행중)를 원래 시작 시각 그대로 되돌린다.
      expect(actions.restored?.status, TodoStatus.inProgress);
      expect(actions.restored?.startedAt, DateTime.utc(2026, 5, 27, 10));
    });

    testWidgets('떠 있는 삭제 되돌리기는 완료 스낵바가 밀어내지 않는다', (tester) async {
      final actions = _FakeActions();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => showUndoSnackbar(
                      context,
                      message: '"다른 일" 삭제됨',
                      onUndo: () {},
                    ),
                    child: const Text('delete'),
                  ),
                  TextButton(
                    onPressed: () => toggleWithUndo(context, actions, make()),
                    child: const Text('check'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('check'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('"다른 일" 삭제됨'), findsOneWidget);
      expect(find.text('"보고서 쓰기" 완료'), findsNothing);
    });

    testWidgets('줄이 사라져도(완료로 목록에서 빠짐) 스낵바는 뜬다', (tester) async {
      final actions = _FakeActions(delay: const Duration(milliseconds: 50));
      final show = ValueNotifier(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (_, visible, _) => visible
                  ? Builder(
                      builder: (rowContext) => TextButton(
                        onPressed: () {
                          toggleWithUndo(rowContext, actions, make());
                          show.value = false; // 저장 도중 줄이 빠진다.
                        },
                        child: const Text('check'),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.tap(find.text('check'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('"보고서 쓰기" 완료'), findsOneWidget);
    });

    testWidgets('완료 취소 쪽은 스낵바 없음', (tester) async {
      final actions = _FakeActions();
      final done = make(doneAt: DateTime.utc(2026, 5, 27, 10));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => toggleWithUndo(context, actions, done),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('check'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('되돌리기'), findsNothing);
    });
  });
}

class _FakeActions implements TodoActionsController {
  _FakeActions({this.delay = Duration.zero});

  final Duration delay;
  Todo? restored;

  @override
  Future<Todo> toggle(Todo todo) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return todo.toggleDone(now: () => DateTime.utc(2026, 5, 27, 11));
  }

  @override
  Future<void> restoreStatus(Todo before) async => restored = before;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
