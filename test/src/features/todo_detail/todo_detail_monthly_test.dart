import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
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

/// 상세 화면 — 매달 손으로 만드는 항목에 "매월 반복 만들기" 제안 (2026-09-25).
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  late MemoryUiPrefsStore prefs;
  final now = DateTime.utc(2026, 5, 30, 9);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    prefs = MemoryUiPrefsStore();
  });
  tearDown(() async => db.close());

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
          uiPrefsStoreProvider.overrideWithValue(prefs),
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
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
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

  Todo monthly(String id, int month) => Todo(
    id: id,
    title: '아파트 관리비 $month월분 입금',
    category: Category.daily,
    createdAt: DateTime.utc(2026, month, 20),
    updatedAt: DateTime.utc(2026, month, 20),
  );

  testWidgets('3개월 이상 손으로 만든 항목 → 제안 카드 → 시트가 반복으로 미리 채워져 열린다', (tester) async {
    final all = [monthly('m6', 6), monthly('m7', 7), monthly('m8', 8)];
    await mount(tester, all.last, all);

    expect(
      find.byKey(const ValueKey('detail-monthly-suggestion')),
      findsOneWidget,
    );
    expect(find.text('3개월째 매달 직접 추가하고 있어요'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('monthly-suggestion-create')));
    await tester.pumpAndSettle();
    final title = tester.widget<TextField>(
      find.byKey(const ValueKey('add-todo-title')),
    );
    expect(title.controller!.text, '아파트 관리비 입금');
    expect(find.text('반복'), findsWidgets);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
  });

  testWidgets('그만 보기 → 카드가 사라지고 기억된다', (tester) async {
    final all = [monthly('m6', 6), monthly('m7', 7), monthly('m8', 8)];
    await mount(tester, all.last, all);
    await tester.tap(find.byKey(const ValueKey('monthly-suggestion-dismiss')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('detail-monthly-suggestion')),
      findsNothing,
    );
    expect(prefs.data['suggest.monthlyRepeatDismissed'], isNotEmpty);
  });

  testWidgets('2개월뿐이면 제안하지 않는다', (tester) async {
    final all = [monthly('m7', 7), monthly('m8', 8)];
    await mount(tester, all.last, all);
    expect(
      find.byKey(const ValueKey('detail-monthly-suggestion')),
      findsNothing,
    );
  });
}
