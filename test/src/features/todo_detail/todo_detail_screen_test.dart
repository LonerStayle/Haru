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
    int sortOrder = 0,
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
    sortOrder: sortOrder,
  );

  /// 롱프레스(ReorderableDelayedDragStartListener) 후 [dy] 만큼 끌어 놓는다.
  /// 한 번에 옮기면 지연 인식기가 놓치므로 잘게 나눠 민다.
  Future<void> dragTile(WidgetTester tester, String title, double dy) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(title)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final step = dy / 10;
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, step));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    // 재정렬은 비동기 upsert — 저장이 끝날 틈을 준다.
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
  }

  double gapBetween(WidgetTester tester, String from, String to) =>
      tester.getCenter(find.text(to)).dy - tester.getCenter(find.text(from)).dy;

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

  group('상태별 보기 필터', () {
    /// 직속 자식 2건(미완료 c1 / 완료 c2) + c1 아래 완료 손자 1건.
    /// "칩 카운트·필터가 직속이 아니라 자손 전체 기준" 인지 보는 구성.
    Todo parent() => make(id: 'p', title: '부모 폴더');
    final c1 = make(id: 'c1', title: '진행 폴더', parentId: 'p');
    final c2 = make(id: 'c2', title: '끝난 자식', parentId: 'p', doneAt: now);
    final g1 = make(id: 'g1', title: '끝난 손자', parentId: 'c1', doneAt: now);

    testWidgets('칩 카운트는 손자까지 센다', (tester) async {
      final p = parent();
      await mount(tester, p, children: [c1, c2], allTodos: [p, c1, c2, g1]);

      expect(find.text('전체 3'), findsOneWidget);
      expect(find.text('미완료 1'), findsOneWidget);
      expect(find.text('완료 2'), findsOneWidget);
    });

    testWidgets('완료 칩 탭 → 직속이 아닌 손자 완료까지 나온다', (tester) async {
      final p = parent();
      await mount(tester, p, children: [c1, c2], allTodos: [p, c1, c2, g1]);

      // 기본(전체) 에서는 직속 자식만.
      expect(find.text('끝난 손자'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('status-filter-done')));
      await tester.pump();

      expect(find.text('끝난 자식'), findsOneWidget);
      expect(find.text('끝난 손자'), findsOneWidget);
      // 미완료 폴더는 타일에서 빠지고 손자의 부모 경로 라벨로만 남는다.
      final crumb = find.byKey(const ValueKey('todo-tile-breadcrumb'));
      expect(crumb, findsOneWidget);
      expect(tester.widget<Text>(crumb).data, '진행 폴더');
    });

    testWidgets('해당 상태가 0건이면 안내 행', (tester) async {
      final p = parent();
      await mount(tester, p, children: [c1, c2], allTodos: [p, c1, c2, g1]);

      await tester.tap(find.byKey(const ValueKey('status-filter-inProgress')));
      await tester.pump();

      expect(find.text('진행중 항목이 없어요'), findsOneWidget);
    });
  });

  // 대표님 체감 "하위 할일에서는 드래그로 순서를 못 바꾼다" 의 실물 확인.
  // 롱프레스 → 실제 드래그 → 저장까지 한 줄로 이어지는지, 그리고 그 저장이
  // **형제 범위에만** 닿는지(다른 가지는 그대로) 를 실기기와 같은 제스처로 고정한다.
  group('하위 형제 드래그 재정렬', () {
    const hintText = '길게 눌러 순서를 바꿀 수 있어요';
    const sortBlockedText = '일정순 보기에서는 순서를 바꿀 수 없어요 · 수동 정렬에서 변경하세요';
    const filterBlockedText = '상태별 보기에서는 순서를 바꿀 수 없어요 · “전체”에서 변경하세요';

    /// 부모 p 의 직속 자식 3 + "건드리면 안 되는" 다른 가지 2건
    /// (c1 의 자식 g1 / p 와 무관한 root r1).
    ({Todo p, Todo c1, Todo c2, Todo c3, Todo g1, Todo r1}) tree() => (
      p: make(id: 'p', title: '부모 폴더'),
      c1: make(id: 'c1', title: '설계', parentId: 'p', sortOrder: 0),
      c2: make(id: 'c2', title: '구현', parentId: 'p', sortOrder: 1),
      c3: make(id: 'c3', title: '배포', parentId: 'p', sortOrder: 2),
      g1: make(id: 'g1', title: '손자', parentId: 'c1', sortOrder: 5),
      r1: make(id: 'r1', title: '남의 가지', sortOrder: 9),
    );

    Future<void> seed(List<Todo> todos) async {
      for (final t in todos) {
        await repo.upsert(t);
      }
    }

    testWidgets('수동 정렬 — 롱프레스 드래그로 형제 순서가 실제로 바뀐다', (tester) async {
      final t = tree();
      final all = [t.p, t.c1, t.c2, t.c3, t.g1, t.r1];
      await seed(all);

      await mount(tester, t.p, children: [t.c1, t.c2, t.c3], allTodos: all);
      expect(find.text(hintText), findsOneWidget);

      // '설계'(첫째)를 '구현' 아래로.
      await dragTile(tester, '설계', gapBetween(tester, '설계', '구현') + 8);

      expect((await repo.getById('c2'))!.sortOrder, 0);
      expect((await repo.getById('c1'))!.sortOrder, 1);
      expect((await repo.getById('c3'))!.sortOrder, 2);
    });

    testWidgets('재정렬은 형제 sortOrder 만 건드린다 (다른 가지 불변)', (tester) async {
      final t = tree();
      final all = [t.p, t.c1, t.c2, t.c3, t.g1, t.r1];
      await seed(all);

      await mount(tester, t.p, children: [t.c1, t.c2, t.c3], allTodos: all);
      await dragTile(tester, '설계', gapBetween(tester, '설계', '구현') + 8);

      // 자식 가지(g1) 와 다른 root(r1) 는 재부여 대상이 아니다.
      expect((await repo.getById('g1'))!.sortOrder, 5);
      expect((await repo.getById('r1'))!.sortOrder, 9);
      // 부모 자신도 그대로.
      expect((await repo.getById('p'))!.sortOrder, 0);
    });

    testWidgets('일정순 — 안내가 뜨고 드래그해도 sortOrder 가 그대로', (tester) async {
      final t = tree();
      final all = [t.p, t.c1, t.c2, t.c3, t.g1, t.r1];
      await seed(all);

      await mount(
        tester,
        t.p,
        children: [t.c1, t.c2, t.c3],
        allTodos: all,
        sortStore: _MemorySortModeStore()..stored = TodoSortMode.dueDate,
      );
      await tester.pumpAndSettle();

      expect(find.text(sortBlockedText), findsOneWidget);
      expect(find.text(hintText), findsNothing);

      await dragTile(tester, '설계', gapBetween(tester, '설계', '구현') + 8);

      expect((await repo.getById('c1'))!.sortOrder, 0);
      expect((await repo.getById('c2'))!.sortOrder, 1);
      expect((await repo.getById('c3'))!.sortOrder, 2);
    });

    testWidgets('상태별 보기 칩을 누르면 같은 톤의 사유 안내', (tester) async {
      final p = make(id: 'p', title: '부모 폴더');
      final d1 = make(
        id: 'd1',
        title: '끝난 하나',
        parentId: 'p',
        doneAt: now,
        sortOrder: 0,
      );
      final d2 = make(
        id: 'd2',
        title: '끝난 둘',
        parentId: 'p',
        doneAt: now,
        sortOrder: 1,
      );

      await mount(tester, p, children: [d1, d2], allTodos: [p, d1, d2]);
      await tester.tap(find.byKey(const ValueKey('status-filter-done')));
      await tester.pump();

      expect(find.text(filterBlockedText), findsOneWidget);
      expect(find.text(hintText), findsNothing);
    });
  });
}
