import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/search/recent_searches.dart';
import 'package:solo_todo/src/features/search/search_screen.dart';
import 'package:solo_todo/src/features/search/todo_search.dart';
import 'package:solo_todo/src/ui/widgets/highlight_text.dart';

/// UX 개선 Phase 4 — 검색 (개선안 §4-8).
Todo make({
  required String id,
  String title = 't',
  String? description,
  Category? category,
  TodoType type = TodoType.task,
  DateTime? doneAt,
}) => Todo(
  id: id,
  title: title,
  description: description,
  category: category ?? Category.work,
  doneAt: doneAt,
  type: type,
  createdAt: DateTime.utc(2026, 8, 15, 9),
  updatedAt: DateTime.utc(2026, 8, 15, 9),
);

void main() {
  group('searchTodos 필터', () {
    final all = [
      make(id: 'a', title: '회의 준비'),
      make(id: 'b', title: '회의록', doneAt: DateTime(2026, 8, 1)),
      make(id: 'c', title: '회의 메모', type: TodoType.note),
      make(id: 'd', title: '회의 장소', category: Category.daily),
    ];

    List<String> ids(List<TodoSearchHit> hits) => [
      for (final h in hits) h.todo.id,
    ];

    test('완료 제외', () {
      expect(
        ids(searchTodos(all: all, query: '회의', includeDone: false)),
        isNot(contains('b')),
      );
    });

    test('메모만', () {
      expect(ids(searchTodos(all: all, query: '회의', notesOnly: true)), ['c']);
    });

    test('카테고리로 좁히기', () {
      expect(
        ids(searchTodos(all: all, query: '회의', categoryId: Category.daily.id)),
        ['d'],
      );
    });

    test('경로 맨 앞에 그룹 이름이 붙는다', () {
      final cat = Category.work.copyWith(groupId: 'g1');
      final hits = searchTodos(
        all: [make(id: 'x', title: '보고서', category: cat)],
        query: '보고',
        groupLabels: {'g1': '업무'},
      );
      expect(hits.single.breadcrumb, '업무 › ${cat.label}');
    });
  });

  test('HighlightText.matchRanges — 대소문자 무시, 겹치지 않게', () {
    expect(HighlightText.matchRanges('API api Api', 'api'), [
      (0, 3),
      (4, 7),
      (8, 11),
    ]);
    expect(HighlightText.matchRanges('abc', ''), isEmpty);
  });

  group('최근 검색어', () {
    test('맨 앞에 쌓이고, 중복은 앞으로, 최대 5개, 저장된다', () async {
      final store = MemoryUiPrefsStore();
      final c = ProviderContainer(
        overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(recentSearchesProvider.notifier);
      await n.restored;
      for (final q in ['a', 'b', 'c', 'd', 'e', 'f', 'b', '  ']) {
        n.record(q);
      }
      expect(c.read(recentSearchesProvider), ['b', 'f', 'e', 'd', 'c']);
      expect(store.lists[RecentSearchesNotifier.storageKey], [
        'b',
        'f',
        'e',
        'd',
        'c',
      ]);
    });

    test('복원 전에 기록해도 저장값을 덮어쓰지 않는다', () async {
      final store = MemoryUiPrefsStore()
        ..lists[RecentSearchesNotifier.storageKey] = ['old1', 'old2'];
      final c = ProviderContainer(
        overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(recentSearchesProvider.notifier)..record('new');
      await n.restored;
      expect(c.read(recentSearchesProvider), ['new', 'old1', 'old2']);
    });
  });

  group('화면', () {
    Future<({List<String> revealed, List<String> edited})> mount(
      WidgetTester tester, {
      required List<Todo> todos,
      FormFactor form = FormFactor.desktop,
      MemoryUiPrefsStore? prefs,
    }) async {
      AppPlatform.debugFormFactorOverride = form;
      addTearDown(() => AppPlatform.debugFormFactorOverride = null);
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final revealed = <String>[];
      final edited = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            allTodosProvider.overrideWith((_) => Stream.value(todos)),
            archivedCategoryIdsProvider.overrideWithValue(const <String>{}),
            categoriesProvider.overrideWith(
              (_) => Stream.value(Category.builtinSeeds),
            ),
            groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
            uiPrefsStoreProvider.overrideWithValue(
              prefs ?? MemoryUiPrefsStore(),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    key: const ValueKey('open-search'),
                    onPressed: () => SearchScreen.show(
                      context,
                      onReveal: (t) => revealed.add(t.id),
                      onEdit: (t) => edited.add(t.id),
                    ),
                    child: const Text('검색'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('open-search')));
      await tester.pumpAndSettle();
      return (revealed: revealed, edited: edited);
    }

    Future<void> type(WidgetTester tester, String q) async {
      await tester.enterText(find.byKey(const ValueKey('search-field')), q);
      await tester.pumpAndSettle();
    }

    final todos = [
      make(id: '1', title: '회의 준비'),
      make(id: '2', title: '주간 회의'),
      make(id: '3', title: '회의록 정리', doneAt: DateTime(2026, 8, 1)),
    ];

    testWidgets('데스크탑은 전체 화면이 아닌 오버레이 + 키 안내', (tester) async {
      await mount(tester, todos: todos);
      expect(find.byKey(const ValueKey('search-overlay')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-key-hints')), findsOneWidget);
      // 뒤 화면이 그대로 남아 있다(덮지 않는다).
      expect(find.byKey(const ValueKey('open-search')), findsOneWidget);
    });

    testWidgets('결과 수와 일치 부분 강조가 보인다', (tester) async {
      await mount(tester, todos: todos);
      await type(tester, '회의');
      expect(find.text('3건'), findsOneWidget);
      expect(find.byType(HighlightText), findsNWidgets(3));
    });

    testWidgets('↓ 로 고르고 ↩ 로 열면 그 위치로(오버레이 닫힘)', (tester) async {
      final m = await mount(tester, todos: todos);
      await type(tester, '회의');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      // 순서: 제목이 "회의"로 시작하는 1·3 → 중간 일치 2. ↓ 한 번 = 두 번째(3).
      expect(m.revealed, ['3']);
      expect(find.byKey(const ValueKey('search-overlay')), findsNothing);
    });

    testWidgets('⌘↩ 는 편집', (tester) async {
      final m = await mount(tester, todos: todos);
      await type(tester, '주간');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(m.edited, ['2']);
      expect(m.revealed, isEmpty);
    });

    testWidgets('결과를 누르면 그 위치로 연다', (tester) async {
      final m = await mount(tester, todos: todos);
      await type(tester, '주간');
      await tester.tap(find.text('주간 회의'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(m.revealed, ['2']);
    });

    testWidgets('"완료 포함" 을 끄면 완료 항목이 빠진다', (tester) async {
      await mount(tester, todos: todos);
      await type(tester, '회의');
      await tester.tap(find.byKey(const ValueKey('search-filter-done')));
      await tester.pumpAndSettle();
      expect(find.text('2건'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-hit-3')), findsNothing);
    });

    testWidgets('열어 본 검색어가 최근 검색에 남고, 누르면 다시 찾는다', (tester) async {
      final prefs = MemoryUiPrefsStore();
      await mount(tester, todos: todos, prefs: prefs);
      await type(tester, '주간');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // 다시 열면 최근 검색이 보인다.
      await tester.tap(find.byKey(const ValueKey('open-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-recent-주간')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-recent-주간')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-hit-2')), findsOneWidget);
    });

    testWidgets('폰은 전체 화면 페이지(오버레이 아님)', (tester) async {
      await mount(tester, todos: todos, form: FormFactor.mobile);
      expect(find.byKey(const ValueKey('search-overlay')), findsNothing);
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('search-filter-done')), findsOneWidget);
    });
  });
}
