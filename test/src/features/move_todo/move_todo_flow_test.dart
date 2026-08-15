import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/move_todo/move_todo_sheet.dart';
import 'package:solo_todo/src/features/todo_actions/todo_actions_controller.dart';

/// 이동 flow **전체** — 시트 선택부터 로컬 DB 반영까지 한 번에 검증한다.
///
/// 기존 테스트는 시트가 돌려주는 [MoveDestination] (widget) 과
/// [TodoActionsController.moveTo] (data) 를 따로 검증할 뿐, 둘을 잇는
/// [showMoveTodoSheet] 는 아무도 통과시키지 않았다. "최상위로 를 눌렀는데
/// 그대로 하위에 남는다" 는 정확히 그 사이에서 나는 증상이라 여기서 막는다.
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;

  final created = DateTime.utc(2026, 8, 9, 9);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
  });

  tearDown(() async => db.close());

  Todo node(
    String id, {
    String? parentId,
    Category category = Category.work,
    int sortOrder = 0,
  }) => Todo(
    id: id,
    title: id,
    category: category,
    dueAt: null,
    doneAt: null,
    createdAt: created,
    updatedAt: created,
    calendarEventId: null,
    parentId: parentId,
    sortOrder: sortOrder,
  );

  /// 실제 앱 구성 그대로 — in-memory DB + 실제 repository/actions provider.
  /// 버튼을 눌러 [showMoveTodoSheet] 를 화면 context 로 띄운다.
  Future<void> openFlow(WidgetTester tester, Todo item) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeCategoriesProvider.overrideWithValue(
            const AsyncValue.data([Category.work, Category.daily]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showMoveTodoSheet(context, ref, item: item),
                  child: const Text('이동'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이동'));
    await tester.pumpAndSettle();
  }

  /// 트리를 걷어내고 drift 구독이 남긴 timer 를 소진시킨다.
  ///
  /// ProviderScope dispose → QueryStream cancel 은 `Timer(Duration.zero)` 를
  /// 남기는데, 그게 프레임 밖에서 정리되지 않으면 flutter_test 가
  /// "A Timer is still pending" 으로 테스트를 죽인다.
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // zero-duration timer 는 시간이 실제로 전진해야 소진된다 (pump() 만으론 남는다).
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('하위 → 최상위 — "최상위로" 확정이 DB 까지 반영된다', (tester) async {
    await repo.upsert(node('a'));
    await repo.upsert(node('b', parentId: 'a'));

    await openFlow(tester, node('b', parentId: 'a'));

    await tester.tap(find.byKey(const ValueKey('move-target-root')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    final moved = await repo.getById('b');
    expect(moved!.parentId, isNull, reason: '회사 최상위로 올라와야 한다');
    expect(moved.category.id, 'work');

    await disposeTree(tester);
  });

  testWidgets('하위 → 최상위 — 자손도 함께 따라 올라온다', (tester) async {
    await repo.upsert(node('a'));
    await repo.upsert(node('b', parentId: 'a'));
    await repo.upsert(node('c', parentId: 'b'));

    await openFlow(tester, node('b', parentId: 'a'));

    await tester.tap(find.byKey(const ValueKey('move-target-root')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    expect((await repo.getById('b'))!.parentId, isNull);
    expect(
      (await repo.getById('c'))!.parentId,
      'b',
      reason: 'c 는 b 밑에 그대로 — 서브트리째 올라온다',
    );

    await disposeTree(tester);
  });

  /// 편집 시트를 열고 그 안의 '이동' 버튼으로 이동 시트까지 가는 실제 경로.
  ///
  /// 편집 시트는 **닫힘 = 자동 저장**이라, '이동' 을 누르면 닫히면서 저장이 한 번
  /// 돌고 그 다음 이동 시트가 열린다. 두 저장이 서로를 덮지 않는지가 관건.
  Future<void> openViaEditSheet(WidgetTester tester, Todo item) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeCategoriesProvider.overrideWithValue(
            const AsyncValue.data([Category.work, Category.daily]),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => AddTodoSheet.show(
                    context,
                    initialCategory: item.category,
                    initialTodo: item,
                    onSubmit: (_) {},
                    onUpdate: (updated) =>
                        ref.read(todoActionsProvider).update(updated),
                    onRequestMove: (t) =>
                        showMoveTodoSheet(context, ref, item: t),
                  ),
                  child: const Text('편집'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-move')));
    await tester.pumpAndSettle();
  }

  testWidgets('편집 시트 → 이동 → 최상위 — 자동 저장이 이동을 덮지 않는다', (tester) async {
    await repo.upsert(node('a'));
    await repo.upsert(node('b', parentId: 'a'));

    await openViaEditSheet(tester, node('b', parentId: 'a'));

    await tester.tap(find.byKey(const ValueKey('move-target-root')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    expect(
      (await repo.getById('b'))!.parentId,
      isNull,
      reason: '편집 시트 닫힘 저장이 이동 결과를 되돌리면 안 된다',
    );

    await disposeTree(tester);
  });

  testWidgets('최상위 → 하위 — 다른 최상위 항목 밑으로 들어간다', (tester) async {
    // "최상위에서 하위로는 못 옮긴다" 는 제보 확인용. 시트 목록에서 다른 root 를
    // 골라 확정하는 경로가 DB 까지 닿는지 본다 (반대 방향만 검증돼 있었다).
    await repo.upsert(node('a'));
    await repo.upsert(node('b'));

    await openFlow(tester, node('b'));

    await tester.tap(find.byKey(const ValueKey('move-target-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    final moved = await repo.getById('b');
    expect(moved!.parentId, 'a', reason: 'a 의 하위로 내려가야 한다');

    await disposeTree(tester);
  });

  testWidgets('최상위 → 하위 — 자손도 서브트리째 따라 내려간다', (tester) async {
    await repo.upsert(node('a'));
    await repo.upsert(node('b'));
    await repo.upsert(node('c', parentId: 'b'));

    await openFlow(tester, node('b'));

    await tester.tap(find.byKey(const ValueKey('move-target-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    expect((await repo.getById('b'))!.parentId, 'a');
    expect((await repo.getById('c'))!.parentId, 'b');

    await disposeTree(tester);
  });

  testWidgets('다른 카테고리 항목의 하위로 옮기면 카테고리도 따라간다', (tester) async {
    await repo.upsert(node('a', category: Category.daily));
    await repo.upsert(node('b'));

    await openFlow(tester, node('b'));

    await tester.tap(find.byKey(const ValueKey('move-category-daily')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-target-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    final moved = await repo.getById('b');
    expect(moved!.parentId, 'a');
    expect(moved.category.id, 'daily', reason: '자식은 부모 카테고리를 상속한다');

    await disposeTree(tester);
  });

  testWidgets('다른 카테고리 최상위로도 이동한다', (tester) async {
    await repo.upsert(node('a'));
    await repo.upsert(node('b', parentId: 'a'));

    await openFlow(tester, node('b', parentId: 'a'));

    await tester.tap(find.byKey(const ValueKey('move-category-daily')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('move-confirm')));
    await tester.pumpAndSettle();

    final moved = await repo.getById('b');
    expect(moved!.parentId, isNull);
    expect(moved.category.id, 'daily');

    await disposeTree(tester);
  });
}
