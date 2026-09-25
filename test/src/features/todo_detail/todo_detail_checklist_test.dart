import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';

class _SortStore implements SortModePreference {
  @override
  Future<TodoSortMode> load() async => TodoSortMode.manual;

  @override
  Future<void> save(TodoSortMode mode) async {}
}

/// 상세 화면 — 설명 속 목록을 하위 항목으로 옮기기 (2026-09-25).
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  final now = DateTime.utc(2026, 5, 30, 9);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
  });
  tearDown(() async => db.close());

  Todo make(String id, {String? parentId, String? description}) => Todo(
    id: id,
    title: '제목-$id',
    description: description,
    category: Category.work,
    createdAt: now,
    updatedAt: now,
    parentId: parentId,
  );

  /// 기본 화면 위에 상세를 push 한 상태로 띄운다 (닫힘 확인용).
  Future<StreamController<List<Todo>>> mount(
    WidgetTester tester,
    Todo parent,
    List<Todo> all,
  ) async {
    final stream = StreamController<List<Todo>>.broadcast();
    addTearDown(stream.close);
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => now),
          todoRepositoryProvider.overrideWithValue(repo),
          sortModePreferenceProvider.overrideWithValue(_SortStore()),
          allTodosProvider.overrideWith((_) async* {
            yield all;
            yield* stream.stream;
          }),
          childrenOfProvider.overrideWith(
            (_, pid) => Stream.value([
              for (final t in all)
                if (t.parentId == pid) t,
            ]),
          ),
          groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TodoDetailScreen(parent: parent),
                    ),
                  ),
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
    return stream;
  }

  Future<List<Todo>> childrenInDb(String pid) async {
    final rows = await db.select(db.todos).get();
    final kids = [
      for (final r in rows)
        if (r.parentId == pid) (await repo.getById(r.id))!,
    ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return kids;
  }

  testWidgets('목록이 2줄 이상이면 제안 → 누르면 하위 항목 + 설명 정리, 되돌리기로 원복', (tester) async {
    final p = make('p', description: '배경 설명\n- **첫째**\n- [x] 둘째\n- 셋째');
    await repo.upsert(p);
    await mount(tester, p, [p]);

    expect(find.text('설명에 목록 3개가 있어요'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('detail-checklist-convert')));
    await tester.pumpAndSettle();

    final kids = await childrenInDb('p');
    expect(kids.map((k) => k.title), ['첫째', '둘째', '셋째']);
    expect(kids.map((k) => k.isDone), [false, true, false]);
    expect(kids.every((k) => k.category == Category.work), isTrue);
    expect((await repo.getById('p'))!.description, '배경 설명');
    expect(find.text('설명 목록 3개를 하위 항목으로 옮겼어요.'), findsOneWidget);

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect(await childrenInDb('p'), isEmpty);
    expect(
      (await repo.getById('p'))!.description,
      '배경 설명\n- **첫째**\n- [x] 둘째\n- 셋째',
    );
  });

  testWidgets('목록이 한 줄뿐이거나 없으면 제안하지 않는다', (tester) async {
    final p = make('p', description: '메모\n- 하나뿐');
    await repo.upsert(p);
    await mount(tester, p, [p]);
    expect(
      find.byKey(const ValueKey('detail-checklist-suggestion')),
      findsNothing,
    );
  });
}
