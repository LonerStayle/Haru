import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 상세 화면 Phase 2 — 부모 카드(바로 고치기) · ⋮ 삭제 · 외부 삭제 시 자동 닫힘.
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

  testWidgets('부모 카드 — 제목을 눌러 바로 고치면 저장된다', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p, [p]);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('detail-parent-card')),
        matching: find.text('제목-p'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('detail-title-field')),
      '새 제목',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect((await repo.getById('p'))!.title, '새 제목');
  });

  testWidgets('부모 카드 — 바꾸지 않고 닫으면 저장하지 않는다', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p, [p]);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('detail-parent-card')),
        matching: find.text('제목-p'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect((await repo.getById('p'))!.updatedAt, now, reason: '열람만으로 쓰지 않음');
  });

  testWidgets('부모 카드 — 설명 추가', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p, [p]);

    await tester.tap(find.text('설명 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('detail-description-field')),
      '메모 내용',
    );
    // 바깥을 눌러 포커스를 빼면 저장.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect((await repo.getById('p'))!.description, '메모 내용');
  });

  testWidgets('Esc 는 버리지 않고 저장한다 (닫힘 = 저장)', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p, [p]);

    await tester.tap(find.text('설명 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('detail-description-field')),
      '긴 설명',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect((await repo.getById('p'))!.description, '긴 설명');
  });

  testWidgets('⋮ 삭제 → 하위까지 지우고 닫힌 뒤 되돌리기 스낵바', (tester) async {
    final p = make('p');
    final c = make('c', parentId: 'p');
    await repo.upsert(p);
    await repo.upsert(c);
    await mount(tester, p, [p, c]);

    await tester.tap(find.byKey(const ValueKey('detail-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('todo-tile-menu-item-delete')));
    await tester.pumpAndSettle();

    expect(find.byType(TodoDetailScreen), findsNothing, reason: '화면 닫힘');
    expect(await repo.getById('p'), isNull);
    expect(await repo.getById('c'), isNull);
    expect(find.text('"제목-p"(하위 1개 포함) 삭제됨'), findsOneWidget);

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect(await repo.getById('p'), isNotNull);
    expect(await repo.getById('c'), isNotNull);
  });

  testWidgets('다른 곳에서 지워지면 자동으로 닫고 알린다', (tester) async {
    final p = make('p');
    final stream = await mount(tester, p, [p]);
    expect(find.byType(TodoDetailScreen), findsOneWidget);

    stream.add(const []);
    await tester.pumpAndSettle();

    expect(find.byType(TodoDetailScreen), findsNothing);
    expect(find.textContaining('다른 곳에서 삭제돼 닫았어요'), findsOneWidget);
  });

  // 목록 스트림이 이전 값을 든 채 error/loading 을 한 번 거치면 asData 가 null 이 돼
  // "목록이 비었다 = 지워졌다" 로 오판했다 (메모 등록 중 상세가 닫히며 삭제 알림).
  testWidgets('목록 스트림이 잠깐 에러여도 지워진 걸로 보지 않는다', (tester) async {
    final p = make('p');
    final stream = await mount(tester, p, [p]);

    stream.addError(StateError('일시 오류'));
    await tester.pumpAndSettle();

    expect(find.byType(TodoDetailScreen), findsOneWidget);
    expect(find.textContaining('다른 곳에서 삭제돼 닫았어요'), findsNothing);
  });

  testWidgets('하위가 없으면 빈 상태에 "하위 추가" 버튼', (tester) async {
    final p = make('p');
    await mount(tester, p, [p]);
    expect(find.byKey(const ValueKey('detail-empty-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-progress')), findsNothing);
  });

  testWidgets('detail-progress 키는 하나만 (진척 막대)', (tester) async {
    final p = make('p');
    final c = make('c', parentId: 'p');
    await mount(tester, p, [p, c]);
    expect(find.byKey(const ValueKey('detail-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-in-progress')), findsOneWidget);
  });
}
