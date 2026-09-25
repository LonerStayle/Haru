import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/backlog/stale_backlog_screen.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

/// 오래된 할 일 정리 화면 (2026-09-25).
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  final now = DateTime(2026, 9, 25, 10);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
  });
  tearDown(() async => db.close());

  Todo make(String id, int ageDays, {String? parentId}) {
    final created = now.subtract(Duration(days: ageDays));
    return Todo(
      id: id,
      title: '제목-$id',
      category: Category.work,
      createdAt: created,
      updatedAt: created,
      parentId: parentId,
    );
  }

  Future<void> mount(WidgetTester tester, List<Todo> all) async {
    for (final t in all) {
      await repo.upsert(t);
    }
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => now),
          todoRepositoryProvider.overrideWithValue(repo),
          allTodosProvider.overrideWith((_) => Stream.value(all)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const StaleBacklogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('30일 넘은 것만 오래된 순으로, 하위 수와 나이를 보여 준다', (tester) async {
    await mount(tester, [
      make('new', 5),
      make('b', 40),
      make('a', 100),
      make('a1', 100, parentId: 'a'),
    ]);
    expect(find.byKey(const ValueKey('stale-row-new')), findsNothing);
    expect(find.byKey(const ValueKey('stale-row-a1')), findsNothing);
    final ya = tester.getTopLeft(find.byKey(const ValueKey('stale-row-a'))).dy;
    final yb = tester.getTopLeft(find.byKey(const ValueKey('stale-row-b'))).dy;
    expect(ya, lessThan(yb));
    expect(find.text('회사 할일 · 100일 전 · 하위 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('stale-action-bar')), findsNothing);
  });

  testWidgets('골라서 완료 → 되돌리기로 원래대로', (tester) async {
    await mount(tester, [make('a', 100), make('b', 40)]);
    await tester.tap(find.byKey(const ValueKey('stale-select-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stale-complete')));
    await tester.pumpAndSettle();
    expect((await repo.getById('a'))!.isDone, isTrue);
    expect((await repo.getById('b'))!.isDone, isFalse);

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect((await repo.getById('a'))!.isDone, isFalse);
  });

  testWidgets('모두 선택 → 오늘로: 종일 오늘 날짜가 잡힌다', (tester) async {
    await mount(tester, [make('a', 100), make('b', 40)]);
    await tester.tap(find.byKey(const ValueKey('stale-select-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stale-today')));
    await tester.pumpAndSettle();
    for (final id in ['a', 'b']) {
      final t = (await repo.getById(id))!;
      expect(t.dueAt!.toLocal(), DateTime(2026, 9, 25));
      expect(t.isAllDay, isTrue);
    }
  });

  testWidgets('삭제는 확인 후 하위까지, 되돌리기로 모두 복원', (tester) async {
    await mount(tester, [
      make('a', 100),
      make('a1', 100, parentId: 'a'),
      make('b', 40),
    ]);
    await tester.tap(find.byKey(const ValueKey('stale-select-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stale-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stale-confirm-delete')));
    await tester.pumpAndSettle();
    expect(await repo.getById('a'), isNull);
    expect(await repo.getById('a1'), isNull);
    expect(await repo.getById('b'), isNotNull);

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect(await repo.getById('a'), isNotNull);
    expect(await repo.getById('a1'), isNotNull);
  });

  testWidgets('없으면 빈 상태', (tester) async {
    await mount(tester, [make('new', 3)]);
    expect(find.text('오래된 할 일이 없어요'), findsOneWidget);
  });
}
