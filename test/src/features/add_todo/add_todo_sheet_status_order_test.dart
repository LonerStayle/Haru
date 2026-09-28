import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/todo_actions/todo_actions_controller.dart';

import '../../../helpers/add_todo_sheet_helpers.dart';

/// 편집 시트의 3-상태 탭이 **자리(sortOrder)를 튀게 하지 않는지** — 실제 컨트롤러 +
/// 저장소까지 태워 최종 저장값으로 고정한다.
///
/// 이 앱의 확립된 불변식은 "순서는 명시적 조작으로만 바뀐다" 이다. 목록 타일의 체크·
/// 세모 토글이 자리를 안 바꾸므로, 의미가 같은 시트의 □/△/◯ 탭도 안 바꿔야 한다.
/// 반대로 **제목 등 내용을 고쳤을 때의 "맨 위로" 규칙은 그대로 살아 있어야** 한다 —
/// 순서 보존을 넓게 적용하다 그 규칙까지 죽이는 것도 회귀다.
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;

  const seedOrder = 7;
  final created = DateTime.utc(2026, 8, 20);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
  });

  tearDown(() async => db.close());

  Todo seed() => Todo(
    id: 'edit-1',
    title: '상태 바꿀 항목',
    category: Category.work,
    createdAt: created,
    updatedAt: created,
    sortOrder: seedOrder,
  );

  /// 같은 형제 중 이 항목보다 위(작은 sortOrder)에 있는 이웃 — bump 가 일어나면
  /// 최종 sortOrder 가 이 값보다 작아진다.
  Todo sibling() => Todo(
    id: 'sibling',
    title: '이웃',
    category: Category.work,
    createdAt: created,
    updatedAt: created,
    sortOrder: 3,
  );

  /// [initial] 은 시트가 여는 스냅샷 — 저장소에 넣어 둔 값과 반드시 같아야 한다
  /// (시트가 다른 상태로 열리면 같은 칸 탭이 no-op 이 되어 테스트가 헛돈다).
  Future<void> mountSheet(WidgetTester tester, {Todo? initial}) async {
    await tester.binding.setSurfaceSize(const Size(700, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todoRepositoryProvider.overrideWithValue(repo),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final actions = ref.read(todoActionsProvider);
                return Center(
                  child: ElevatedButton(
                    key: const ValueKey('open-sheet'),
                    onPressed: () => AddTodoSheet.show(
                      context,
                      initialCategory: Category.work,
                      initialTodo: initial ?? seed(),
                      onSubmit: (_) {},
                      // 실제 화면들과 동일한 배선.
                      onUpdate: (updated) => actions.update(updated),
                      onStatusChanged: (updated) =>
                          actions.updatePreservingOrder(updated),
                    ),
                    child: const Text('열기'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();
    await openSheetMore(tester);
  }

  Future<void> tapStatus(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  Future<void> tapBarrier(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  Future<Todo> saved() async => (await repo.getById('edit-1'))!;

  for (final (key, label) in const [
    ('status-inProgress', '△ 진행중'),
    ('status-done', '◯ 완료'),
  ]) {
    testWidgets('$label 로 바꿔도 sortOrder 가 그대로다', (tester) async {
      await repo.upsert(seed());
      await repo.upsert(sibling());
      await mountSheet(tester);

      await tapStatus(tester, key);

      final row = await saved();
      expect(row.sortOrder, seedOrder, reason: '상태 변경은 자리를 바꾸지 않는다');
      expect(row.status, isNot(TodoStatus.undone), reason: '상태는 실제로 저장됐어야 함');
    });
  }

  testWidgets('□ 미완료 로 되돌려도 sortOrder 가 그대로다', (tester) async {
    final done = seed().copyWith(doneAt: DateTime.utc(2026, 8, 26));
    await repo.upsert(done);
    await repo.upsert(sibling());
    await mountSheet(tester, initial: done);

    await tapStatus(tester, 'status-undone');

    final row = await saved();
    expect(row.sortOrder, seedOrder);
    expect(row.status, TodoStatus.undone);
  });

  testWidgets('상태만 바꾸고 시트를 닫아도 sortOrder 가 그대로다 (닫힘 저장이 bump 하지 않는다)', (
    tester,
  ) async {
    await repo.upsert(seed());
    await repo.upsert(sibling());
    await mountSheet(tester);

    await tapStatus(tester, 'status-inProgress');
    await tapBarrier(tester);

    expect(find.byType(AddTodoSheet), findsNothing);
    final row = await saved();
    expect(row.sortOrder, seedOrder, reason: '닫힘 저장은 무변경 → no-op 이어야 한다');
    expect(row.status, TodoStatus.inProgress);
  });

  testWidgets('제목을 고치면 기존 "편집하면 맨 위로" 규칙은 그대로 살아 있다', (tester) async {
    await repo.upsert(seed());
    await repo.upsert(sibling());
    await mountSheet(tester);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '고친 제목',
    );
    await tester.pump();
    await tapBarrier(tester);

    final row = await saved();
    expect(row.title, '고친 제목');
    expect(row.sortOrder, lessThan(3), reason: '내용 편집은 형제 min-1 로 bump');
  });

  testWidgets('상태를 바꾼 뒤 제목까지 고치면 그때는 맨 위로 (두 규칙이 서로를 막지 않는다)', (tester) async {
    await repo.upsert(seed());
    await repo.upsert(sibling());
    await mountSheet(tester);

    await tapStatus(tester, 'status-done');
    expect((await saved()).sortOrder, seedOrder);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '고친 제목',
    );
    await tester.pump();
    await tapBarrier(tester);

    final row = await saved();
    expect(row.title, '고친 제목');
    expect(row.status, TodoStatus.done, reason: '닫힘 저장이 상태를 되돌리면 안 된다');
    expect(row.sortOrder, lessThan(3));
  });
}
