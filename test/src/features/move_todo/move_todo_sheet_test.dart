import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/move_todo/move_todo_sheet.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

void main() {
  final now = DateTime.utc(2026, 8, 9, 9);

  Todo make({
    required String id,
    String? title,
    String? parentId,
    Category category = Category.work,
    int sortOrder = 0,
  }) => Todo(
    id: id,
    title: title ?? id,
    category: category,
    dueAt: null,
    doneAt: null,
    createdAt: now,
    updatedAt: now,
    calendarEventId: null,
    parentId: parentId,
    sortOrder: sortOrder,
  );

  // 회사: 넥서스 > 캔버스 > 렌더,  리팩터링(독립 root)
  // 일상: 장보기
  final nexus = make(id: 'nexus', title: '넥서스');
  final canvas = make(id: 'canvas', title: '캔버스', parentId: 'nexus');
  final render = make(id: 'render', title: '렌더', parentId: 'canvas');
  final refactor = make(id: 'refactor', title: '리팩터링', sortOrder: 1);
  final grocery = make(id: 'grocery', title: '장보기', category: Category.daily);
  final all = [nexus, canvas, render, refactor, grocery];

  /// 시트를 modal 로 띄우고 결과를 담을 홀더를 돌려준다.
  ///
  /// [todos] 를 주면 목록(=최신 상태)과 [item] (=호출자가 들고 있던 스냅샷) 을 일부러
  /// 어긋나게 둘 수 있다 — stale 판정 회귀 검증용.
  Future<List<MoveDestination?>> open(
    WidgetTester tester,
    Todo item, {
    List<Todo>? todos,
  }) async {
    final result = <MoveDestination?>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allTodosProvider.overrideWith((_) => Stream.value(todos ?? all)),
          activeCategoriesProvider.overrideWithValue(
            const AsyncValue.data([Category.work, Category.daily]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result.add(
                      await showModalBottomSheet<MoveDestination>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => MoveTodoSheet(item: item),
                      ),
                    );
                  },
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('선택 카테고리의 트리를 계층 순서대로 보여 준다', (tester) async {
    await open(tester, refactor);

    expect(find.text('넥서스'), findsOneWidget);
    expect(find.text('캔버스'), findsOneWidget);
    expect(find.text('렌더'), findsOneWidget);
    // 다른 카테고리(일상)의 항목은 검색 전에는 안 보인다.
    expect(find.text('장보기'), findsNothing);
  });

  testWidgets('하위 → 다른 항목의 하위 — 대상 선택 후 확정하면 그 부모를 돌려준다', (tester) async {
    // 렌더(캔버스의 하위)를 리팩터링 하위로.
    final result = await open(tester, render);

    await tester.tap(find.byKey(const ValueKey('move-target-refactor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    expect(result.single?.parent?.id, 'refactor');
  });

  testWidgets('하위 → 상위 — "최상위로" 선택 시 parent 가 null', (tester) async {
    final result = await open(tester, canvas);

    await tester.tap(find.byKey(const ValueKey('move-target-root')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    expect(result.single, isNotNull);
    expect(result.single!.parent, isNull);
    expect(result.single!.category.id, 'work');
  });

  testWidgets('다른 카테고리 칩을 고르면 그 트리로 바뀌고 최상위 목적지도 따라간다', (tester) async {
    final result = await open(tester, canvas);

    await tester.tap(find.byKey(const ValueKey('move-category-daily')));
    await tester.pumpAndSettle();

    expect(find.text('장보기'), findsOneWidget);
    expect(find.text('넥서스'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();
    expect(result.single!.parent, isNull);
    expect(result.single!.category.id, 'daily', reason: '일상 최상위로');
  });

  testWidgets('자기 자신·자손은 목록에 있어도 고를 수 없다', (tester) async {
    // 넥서스를 옮기는 중 — 넥서스/캔버스/렌더는 목적지가 될 수 없다.
    await open(tester, nexus);

    for (final id in ['nexus', 'canvas', 'render']) {
      await tester.tap(find.byKey(ValueKey('move-target-$id')));
      await tester.pumpAndSettle();
    }

    // 아무것도 선택되지 않아 최상위(=현재 위치) 그대로 → 확정 비활성.
    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('move-confirm')),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('제자리 이동은 확정 버튼이 비활성', (tester) async {
    // 캔버스는 이미 넥서스의 하위 → 넥서스를 다시 골라도 변화 없음.
    await open(tester, canvas);

    await tester.tap(find.byKey(const ValueKey('move-target-nexus')));
    await tester.pumpAndSettle();

    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('move-confirm')),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('호출자가 옛 스냅샷을 넘겨도 최신 위치로 판정한다', (tester) async {
    // 캔버스는 이미 최상위로 옮겨졌는데(목록=최신), 화면이 넘긴 item 은 아직 넥서스 하위.
    // 옛 스냅샷으로 재면 "최상위로" 가 이동으로 보여 확정이 켜지지만, 실제로는 제자리라
    // 눌러도 아무 일도 안 일어난다 — 확정은 최신 기준으로 꺼져 있어야 한다.
    final movedCanvas = make(id: 'canvas', title: '캔버스');
    await open(
      tester,
      canvas,
      todos: [nexus, movedCanvas, render, refactor, grocery],
    );

    await tester.tap(find.byKey(const ValueKey('move-target-root')));
    await tester.pumpAndSettle();

    final confirm = tester.widget<FilledButton>(
      find.byKey(const ValueKey('move-confirm')),
    );
    expect(confirm.onPressed, isNull, reason: '최신 기준 이미 회사 최상위 → 제자리');
  });

  testWidgets('검색은 카테고리를 넘어 찾고 경로를 함께 보여 준다', (tester) async {
    final result = await open(tester, refactor);

    await tester.enterText(find.byKey(const ValueKey('move-search')), '장보');
    await tester.pumpAndSettle();

    expect(find.text('장보기'), findsOneWidget);
    expect(find.text('넥서스'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('move-target-grocery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    expect(result.single?.parent?.id, 'grocery');
    expect(result.single?.category.id, 'daily', reason: '부모 카테고리를 따라간다');
  });
}
