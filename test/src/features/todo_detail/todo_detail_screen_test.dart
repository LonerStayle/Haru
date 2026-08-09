import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';

/// 정렬 모드 인메모리 저장소 — shared_preferences 플랫폼 채널 없이 화면을 띄운다.
class _MemorySortModeStore implements SortModePreference {
  TodoSortMode stored = TodoSortMode.manual;

  @override
  Future<TodoSortMode> load() async => stored;

  @override
  Future<void> save(TodoSortMode mode) async => stored = mode;
}

void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;

  final now = DateTime.utc(2026, 5, 30, 9);

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
  });

  tearDown(() async => db.close());

  Todo make({
    required String id,
    String title = 't',
    String? parentId,
    TodoType type = TodoType.task,
    DateTime? doneAt,
    DateTime? dueAt,
  }) => Todo(
    id: id,
    title: title,
    category: Category.work,
    dueAt: dueAt,
    doneAt: doneAt,
    createdAt: now,
    updatedAt: now,
    calendarEventId: null,
    parentId: parentId,
    type: type,
  );

  /// 화면에 그려진 순서대로 제목을 수집 (세로 위치 기준).
  List<String> visibleTitles(WidgetTester tester, List<String> candidates) {
    final found = <(double, String)>[];
    for (final title in candidates) {
      final finder = find.text(title);
      if (finder.evaluate().isEmpty) continue;
      found.add((tester.getTopLeft(finder).dy, title));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final e in found) e.$2];
  }

  /// [children] = parent 직속 자식, [allTodos] = childCount 판정용 전체.
  /// watch provider 는 plain Stream override (Drift 타이머 leak 회피), 액션 콜백은
  /// 실제 memory-repo override 로 동작.
  Future<void> mount(
    WidgetTester tester,
    Todo parent, {
    List<Todo> children = const [],
    List<Todo>? allTodos,
    SortModePreference? sortStore,
  }) async {
    final repoOverride = LocalTodoRepository(db.todosDao);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => now),
          todoRepositoryProvider.overrideWithValue(repoOverride),
          sortModePreferenceProvider.overrideWithValue(
            sortStore ?? _MemorySortModeStore(),
          ),
          allTodosProvider.overrideWith(
            (_) => Stream.value(allTodos ?? [parent, ...children]),
          ),
          childrenOfProvider(
            parent.id,
          ).overrideWith((_) => Stream.value(children)),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: TodoDetailScreen(parent: parent),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(Duration.zero);
  }

  testWidgets('AppBar 에 parent 제목 + 직속 자식 리스트 표시', (tester) async {
    final parent = make(id: 'p', title: '회사 프로젝트');
    final child = make(id: 'c1', title: '설계', parentId: 'p');

    await mount(tester, parent, children: [child]);

    expect(find.text('회사 프로젝트'), findsOneWidget); // AppBar title
    expect(find.text('설계'), findsOneWidget); // 직속 자식
  });

  testWidgets('자식 체크 토글 → doneAt 채워짐', (tester) async {
    final parent = make(id: 'p', title: '부모');
    final child = make(id: 'c1', title: '자식', parentId: 'p');
    await repo.upsert(child); // toggle 이 upsert 할 대상.

    await mount(tester, parent, children: [child]);
    expect(find.text('자식'), findsOneWidget);

    // 자식 타일의 체크 버튼 탭.
    await tester.tap(find.byKey(const ValueKey('todo-tile-check')));
    await tester.pump();
    await tester.pump(Duration.zero);

    final fromDb = await repo.getById('c1');
    expect(fromDb!.isDone, isTrue);
  });

  testWidgets('상세 AppBar 체크 토글 → parent doneAt 채워짐', (tester) async {
    final parent = make(id: 'p', title: '부모');
    final child = make(id: 'c1', title: '자식', parentId: 'p');
    await repo.upsert(parent);

    await mount(tester, parent, children: [child]);

    await tester.tap(find.byKey(const ValueKey('detail-toggle')));
    await tester.pump();
    await tester.pump(Duration.zero);

    final fromDb = await repo.getById('p');
    expect(fromDb!.isDone, isTrue);
  });

  testWidgets('자식이 또 자식을 가지면 드릴 배지 표시 (더 깊은 드릴 가능)', (tester) async {
    final parent = make(id: 'p', title: '부모');
    final child = make(id: 'c1', title: '중간 폴더', parentId: 'p');
    final grand = make(id: 'g1', title: '손자', parentId: 'c1');

    await mount(
      tester,
      parent,
      children: [child],
      allTodos: [parent, child, grand],
    );

    expect(find.text('중간 폴더'), findsOneWidget);
    // 자식(c1)이 손자를 가지므로 드릴 배지 노출.
    expect(find.byKey(const ValueKey('todo-tile-drill-c1')), findsOneWidget);
    // 손자는 인라인으로 펼쳐지지 않는다.
    expect(find.text('손자'), findsNothing);
  });

  testWidgets('자식 없으면 빈 상태 + 하위 추가 FAB', (tester) async {
    final parent = make(id: 'p', title: '빈 부모');

    await mount(tester, parent);

    expect(find.text('하위 항목이 없어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-add-child')), findsOneWidget);
  });

  testWidgets('note parent — 체크 토글 없음, 단 ＋하위 추가 FAB 노출 (§14 헤딩)', (
    tester,
  ) async {
    final parent = make(id: 'p', title: '메모', type: TodoType.note);

    await mount(tester, parent);

    // note 는 체크 개념 없음 → 토글 미표시.
    expect(find.byKey(const ValueKey('detail-toggle')), findsNothing);
    // §14 — note 도 섹션 헤딩으로 자식 보유 가능 → 하위 추가 FAB 노출.
    expect(find.byKey(const ValueKey('detail-add-child')), findsOneWidget);
  });

  testWidgets('§14 — note 헤딩 자손 task 진척 요약 노출 (1/2 완료)', (tester) async {
    final parent = make(id: 'p', title: '코기토', type: TodoType.note);
    final c1 = make(id: 'c1', title: '서버', parentId: 'p', doneAt: now);
    final c2 = make(id: 'c2', title: 'DNS', parentId: 'p');

    await mount(tester, parent, children: [c1, c2], allTodos: [parent, c1, c2]);

    expect(find.byKey(const ValueKey('detail-progress')), findsOneWidget);
    expect(find.text('1/2 완료'), findsOneWidget);
  });

  testWidgets('자손에 task 없으면(순수 메모 자식) 진척 바 숨김', (tester) async {
    final parent = make(id: 'p', title: '메모', type: TodoType.note);
    final noteChild = make(
      id: 'nc',
      title: '메모 자식',
      parentId: 'p',
      type: TodoType.note,
    );

    await mount(
      tester,
      parent,
      children: [noteChild],
      allTodos: [parent, noteChild],
    );

    expect(find.byKey(const ValueKey('detail-progress')), findsNothing);
  });

  testWidgets('하위 목록도 AppBar 정렬 버튼으로 일정 빠른 순 정렬', (tester) async {
    final parent = make(id: 'p', title: '부모');
    final late_ = make(
      id: 'c1',
      title: '늦은 하위',
      parentId: 'p',
      dueAt: DateTime.utc(2026, 6, 20, 9),
    );
    final none = make(id: 'c2', title: '날짜 없는 하위', parentId: 'p');
    final early = make(
      id: 'c3',
      title: '빠른 하위',
      parentId: 'p',
      dueAt: DateTime.utc(2026, 6, 2, 9),
    );
    final store = _MemorySortModeStore();

    await mount(
      tester,
      parent,
      children: [late_, none, early],
      sortStore: store,
    );

    const titles = ['늦은 하위', '날짜 없는 하위', '빠른 하위'];
    expect(visibleTitles(tester, titles), titles);

    await tester.tap(find.byKey(const ValueKey('sort-mode-icon-button')));
    await tester.pump();

    expect(visibleTitles(tester, titles), ['빠른 하위', '늦은 하위', '날짜 없는 하위']);
    expect(store.stored, TodoSortMode.dueDate);
  });

  testWidgets('저장된 일정순 설정은 하위 상세 화면에도 그대로 적용된다', (tester) async {
    final parent = make(id: 'p', title: '부모');
    final late_ = make(
      id: 'c1',
      title: '늦은 하위',
      parentId: 'p',
      dueAt: DateTime.utc(2026, 6, 20, 9),
    );
    final early = make(
      id: 'c2',
      title: '빠른 하위',
      parentId: 'p',
      dueAt: DateTime.utc(2026, 6, 2, 9),
    );

    await mount(
      tester,
      parent,
      children: [late_, early],
      sortStore: _MemorySortModeStore()..stored = TodoSortMode.dueDate,
    );
    await tester.pumpAndSettle();

    expect(visibleTitles(tester, ['늦은 하위', '빠른 하위']), ['빠른 하위', '늦은 하위']);
  });
}
