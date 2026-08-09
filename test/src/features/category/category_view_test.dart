import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/category_providers.dart';
import 'package:solo_todo/src/features/category/category_view.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';

/// 정렬 모드 인메모리 저장소 — shared_preferences 플랫폼 채널 없이 화면을 띄운다.
class _MemorySortModeStore implements SortModePreference {
  TodoSortMode stored = TodoSortMode.manual;

  @override
  Future<TodoSortMode> load() async => stored;

  @override
  Future<void> save(TodoSortMode mode) async => stored = mode;
}

void main() {
  Future<StreamController<List<Todo>>> mount(
    WidgetTester tester, {
    required Category category,
    SortModePreference? sortStore,
  }) async {
    final controller = StreamController<List<Todo>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          watchTodosByCategoryProvider(
            category,
          ).overrideWith((_) => controller.stream),
          sortModePreferenceProvider.overrideWithValue(
            sortStore ?? _MemorySortModeStore(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(body: CategoryView(category: category)),
        ),
      ),
    );
    return controller;
  }

  Todo todo({
    required String id,
    required Category category,
    String title = 'x',
    DateTime? doneAt,
    TodoType type = TodoType.task,
    String? description,
    DateTime? dueAt,
  }) => Todo(
    id: id,
    title: title,
    category: category,
    type: type,
    dueAt: dueAt,
    doneAt: doneAt,
    createdAt: DateTime.utc(2026, 5, 27),
    updatedAt: DateTime.utc(2026, 5, 27),
    calendarEventId: null,
    description: description,
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

  testWidgets('빈 list → "{label}에 할 일이 없어요"', (tester) async {
    final controller = await mount(tester, category: Category.work);
    controller.add(<Todo>[]);
    await tester.pump();

    expect(find.text('회사 할일에 할 일이 없어요'), findsOneWidget);
  });

  testWidgets('미체크 2 + 완료 1 → 통계 chip / 완료는 접기 행 아래로', (tester) async {
    final controller = await mount(tester, category: Category.idea);
    controller.add([
      todo(id: '1', category: Category.idea, title: '아이디어 A'),
      todo(id: '2', category: Category.idea, title: '아이디어 B'),
      todo(
        id: '3',
        category: Category.idea,
        title: '아이디어 C 완료',
        doneAt: DateTime.utc(2026, 5, 27, 12),
      ),
    ]);
    await tester.pump();

    // 미체크는 노출.
    expect(find.text('아이디어 A'), findsOneWidget);
    expect(find.text('아이디어 B'), findsOneWidget);
    // 완료는 기본 접힘 — "완료 1개" 접기 행 아래로 숨는다.
    expect(find.text('아이디어 C 완료'), findsNothing);
    expect(find.text('완료 1개'), findsOneWidget);
    // 헤더 통계 chip (미완료/완료) 은 접힘과 무관하게 그대로.
    expect(find.text('미완료 2'), findsOneWidget);
    expect(find.text('완료 1'), findsOneWidget);
    // 접기 행 탭 → 완료 노출.
    await tester.tap(find.byKey(const ValueKey('drill-done-toggle')));
    await tester.pump();
    expect(find.text('아이디어 C 완료'), findsOneWidget);
  });

  testWidgets('메모(note)는 미완료/완료 카운트에서 제외된다', (tester) async {
    final controller = await mount(tester, category: Category.idea);
    controller.add([
      todo(id: '1', category: Category.idea, title: '태스크 미체크'),
      todo(
        id: '2',
        category: Category.idea,
        title: '태스크 완료',
        doneAt: DateTime.utc(2026, 5, 27, 12),
      ),
      // note 는 체크 개념이 없어 카운트에서 빠져야 한다 (예전엔 미체크로 잘못 셈).
      // 제목을 '참고 노트'로 — §13 "메모" 라벨 칩 텍스트와 충돌 회피.
      todo(
        id: '3',
        category: Category.idea,
        title: '참고 노트',
        type: TodoType.note,
      ),
    ]);
    await tester.pump();

    expect(find.text('참고 노트'), findsOneWidget);
    expect(find.text('미완료 1'), findsOneWidget);
    expect(find.text('완료 1'), findsOneWidget);
  });

  testWidgets('헤더에 카테고리 한글 라벨 노출', (tester) async {
    final controller = await mount(tester, category: Category.personalDev);
    controller.add(<Todo>[]);
    await tester.pump();

    expect(find.text('개인개발'), findsAtLeastNWidgets(1));
  });

  testWidgets('§14-B 메모 N 카운트 — note 있으면 헤더에 "메모 N"', (tester) async {
    final controller = await mount(tester, category: Category.idea);
    controller.add([
      todo(id: 't', category: Category.idea, title: '할 일'),
      todo(
        id: 'n1',
        category: Category.idea,
        title: '노트1',
        type: TodoType.note,
      ),
      todo(
        id: 'n2',
        category: Category.idea,
        title: '노트2',
        type: TodoType.note,
      ),
    ]);
    await tester.pump();

    expect(find.text('메모 2'), findsOneWidget);
  });

  testWidgets('§14-B 메모 0 — "메모" 칩 생략', (tester) async {
    final controller = await mount(tester, category: Category.idea);
    controller.add([todo(id: 't', category: Category.idea, title: '할 일')]);
    await tester.pump();

    expect(find.textContaining('메모'), findsNothing);
  });

  testWidgets('§13 혼합 — task=체크 행, note=메모 글리프+라벨+프리뷰 로 시각 구분', (tester) async {
    final controller = await mount(tester, category: Category.idea);
    controller.add([
      todo(id: 't', category: Category.idea, title: '할 일 항목'),
      todo(
        id: 'n',
        category: Category.idea,
        title: '노트 항목',
        type: TodoType.note,
        description: '노트 본문 미리보기',
      ),
    ]);
    await tester.pump();

    // task = trailing 체크 버튼(메모 글리프 없음).
    expect(find.byKey(const ValueKey('todo-tile-check')), findsOneWidget);
    // note = leading 메모 글리프 + "메모" 라벨 + 본문 프리뷰.
    expect(
      find.byKey(const ValueKey('todo-tile-note-leading')),
      findsOneWidget,
    );
    expect(find.text('메모'), findsOneWidget);
    expect(find.text('노트 본문 미리보기'), findsOneWidget);
    // 둘 다 제목 노출.
    expect(find.text('할 일 항목'), findsOneWidget);
    expect(find.text('노트 항목'), findsOneWidget);
  });

  testWidgets('헤더의 "일정순" 버튼 → 목록이 일정 빠른 순으로 재배치', (tester) async {
    final store = _MemorySortModeStore();
    final controller = await mount(
      tester,
      category: Category.work,
      sortStore: store,
    );
    controller.add([
      todo(
        id: '1',
        category: Category.work,
        title: '늦은 일',
        dueAt: DateTime.utc(2026, 8, 20, 9),
      ),
      todo(id: '2', category: Category.work, title: '날짜 없는 일'),
      todo(
        id: '3',
        category: Category.work,
        title: '빠른 일',
        dueAt: DateTime.utc(2026, 8, 3, 9),
      ),
    ]);
    await tester.pump();

    const titles = ['늦은 일', '날짜 없는 일', '빠른 일'];
    // 기본은 수동(들어온) 순서.
    expect(visibleTitles(tester, titles), titles);

    await tester.tap(find.byKey(const ValueKey('sort-mode-button')));
    await tester.pump();

    expect(visibleTitles(tester, titles), ['빠른 일', '늦은 일', '날짜 없는 일']);
    // 선택은 저장된다 (다음 실행에도 유지).
    expect(store.stored, TodoSortMode.dueDate);

    // 다시 누르면 수동 순서로 복귀.
    await tester.tap(find.byKey(const ValueKey('sort-mode-button')));
    await tester.pump();

    expect(visibleTitles(tester, titles), titles);
    expect(store.stored, TodoSortMode.manual);
  });

  testWidgets('저장된 일정순 설정은 화면 진입 시 그대로 복원된다', (tester) async {
    final store = _MemorySortModeStore()..stored = TodoSortMode.dueDate;
    final controller = await mount(
      tester,
      category: Category.work,
      sortStore: store,
    );
    controller.add([
      todo(
        id: '1',
        category: Category.work,
        title: '늦은 일',
        dueAt: DateTime.utc(2026, 8, 20, 9),
      ),
      todo(
        id: '2',
        category: Category.work,
        title: '빠른 일',
        dueAt: DateTime.utc(2026, 8, 3, 9),
      ),
    ]);
    // 저장값 복원(비동기) 후 리스트 반영.
    await tester.pumpAndSettle();

    expect(visibleTitles(tester, ['늦은 일', '빠른 일']), ['빠른 일', '늦은 일']);
  });

  group('상태별 보기 필터', () {
    /// 미완료 root / 진행중 root / 완료 자식 / 메모 — 4상태를 모두 덮는 세트.
    List<Todo> sample() => [
      todo(id: 'u', category: Category.work, title: '미완료 할일'),
      Todo(
        id: 'p',
        title: '진행중 할일',
        category: Category.work,
        startedAt: DateTime.utc(2026, 8, 1, 9),
        createdAt: DateTime.utc(2026, 8, 1),
        updatedAt: DateTime.utc(2026, 8, 1),
      ),
      Todo(
        id: 'd',
        title: '완료된 하위',
        category: Category.work,
        parentId: 'u',
        doneAt: DateTime.utc(2026, 8, 1, 12),
        createdAt: DateTime.utc(2026, 8, 1),
        updatedAt: DateTime.utc(2026, 8, 1),
      ),
      todo(
        id: 'n',
        category: Category.work,
        title: '메모 항목',
        type: TodoType.note,
      ),
    ];

    testWidgets('기본은 전체 — 칩 카운트는 자손까지 센다', (tester) async {
      final controller = await mount(tester, category: Category.work);
      controller.add(sample());
      await tester.pump();

      expect(find.text('전체 4'), findsOneWidget);
      expect(find.text('미완료 1'), findsOneWidget);
      expect(find.text('진행중 1'), findsOneWidget);
      expect(find.text('완료 1'), findsOneWidget);
      expect(find.text('메모 1'), findsOneWidget);
      // 전체 = 기존 트리 — root 만 보이고 완료 자손은 드릴다운 안쪽.
      expect(find.text('미완료 할일'), findsOneWidget);
      expect(find.text('완료된 하위'), findsNothing);
    });

    testWidgets('완료 칩 탭 → 완료 항목만 (자손 포함, 칩 카운트와 일치)', (tester) async {
      final controller = await mount(tester, category: Category.work);
      controller.add(sample());
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('status-filter-done')));
      await tester.pump();

      expect(find.text('완료된 하위'), findsOneWidget);
      expect(find.text('진행중 할일'), findsNothing);
      expect(find.text('메모 항목'), findsNothing);
      // 부모('미완료 할일')는 타일이 아니라 부모 경로 라벨로만 남는다.
      final crumb = find.byKey(const ValueKey('todo-tile-breadcrumb'));
      expect(crumb, findsOneWidget);
      expect(tester.widget<Text>(crumb).data, '미완료 할일');
    });

    testWidgets('진행중 칩 탭 → 진행중만, 다시 전체 칩 탭 → 원래 목록', (tester) async {
      final controller = await mount(tester, category: Category.work);
      controller.add(sample());
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('status-filter-inProgress')));
      await tester.pump();
      expect(find.text('진행중 할일'), findsOneWidget);
      expect(find.text('미완료 할일'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('status-filter-all')));
      await tester.pump();
      expect(find.text('미완료 할일'), findsOneWidget);
      expect(find.text('진행중 할일'), findsOneWidget);
    });

    testWidgets('메모 칩 탭 → note 만', (tester) async {
      final controller = await mount(tester, category: Category.work);
      controller.add(sample());
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('status-filter-note')));
      await tester.pump();

      expect(find.text('메모 항목'), findsOneWidget);
      expect(find.text('미완료 할일'), findsNothing);
    });

    testWidgets('빈 카테고리에서는 칩 줄을 감춘다', (tester) async {
      final controller = await mount(tester, category: Category.work);
      controller.add(<Todo>[]);
      await tester.pump();

      expect(find.byKey(const ValueKey('status-filter-all')), findsNothing);
    });
  });
}
