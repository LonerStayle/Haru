import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/data/todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_readiness.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/search/recent_searches.dart';
import 'package:solo_todo/src/features/search/search_screen.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';

import '../ai/fake_ai_gateway.dart';

/// 쓰기 호출을 세는 저장소 — 물어보기는 한 번도 쓰지 않아야 한다.
class _RecordingRepo implements TodoRepository {
  _RecordingRepo(this.items);

  final List<Todo> items;
  int upserts = 0;
  int deletes = 0;

  @override
  Future<Todo?> getById(String id) async =>
      items.where((t) => t.id == id).firstOrNull;

  @override
  Stream<List<Todo>> watchAll() => Stream.value(items);

  @override
  Stream<List<Todo>> watchByCategory(Category category) => Stream.value([
    for (final t in items)
      if (t.category == category) t,
  ]);

  @override
  Stream<List<Todo>> watchToday(DateTime Function() now) => Stream.value(items);

  @override
  Future<void> upsert(Todo todo) async => upserts++;

  @override
  Future<void> deleteById(String id) async => deletes++;

  @override
  Future<int?> minSiblingSortOrder({
    required String categoryId,
    String? parentId,
  }) async => null;
}

class _SortStore implements SortModePreference {
  @override
  Future<TodoSortMode> load() async => TodoSortMode.manual;

  @override
  Future<void> save(TodoSortMode mode) async {}
}

/// T5 — ⌘K 물어보기 (읽기 전용).
void main() {
  final now = DateTime(2026, 10, 10, 14);

  Todo make(
    String id, {
    String? title,
    Category? category,
    DateTime? doneAt,
    String? description,
  }) => Todo(
    id: id,
    title: title ?? '제목-$id',
    category: category ?? Category.work,
    doneAt: doneAt,
    description: description,
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
  );

  final todos = [
    make('a', title: '회의 준비', description: '안건 세 개 정리'),
    make('b', title: '결제 모듈 리뷰'),
  ];

  late FakeAiGateway ai;
  late _RecordingRepo repo;
  late MemoryUiPrefsStore prefs;
  late StreamController<List<Todo>> todosStream;

  setUp(() {
    ai = FakeAiGateway();
    prefs = MemoryUiPrefsStore();
    todosStream = StreamController<List<Todo>>.broadcast();
  });
  tearDown(() => todosStream.close());

  Future<({List<String> revealed})> mount(
    WidgetTester tester, {
    List<Todo>? items,
    bool ready = true,
    FormFactor form = FormFactor.desktop,
    Set<String> archived = const {},
  }) async {
    final list = items ?? todos;
    repo = _RecordingRepo(list);
    AppPlatform.debugFormFactorOverride = form;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final revealed = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => now),
          todoRepositoryProvider.overrideWithValue(repo),
          sortModePreferenceProvider.overrideWithValue(_SortStore()),
          allTodosProvider.overrideWith((_) async* {
            yield list;
            yield* todosStream.stream;
          }),
          childrenOfProvider.overrideWith((_, _) => Stream.value(const [])),
          archivedCategoryIdsProvider.overrideWithValue(archived),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          uiPrefsStoreProvider.overrideWithValue(prefs),
          aiReadinessProvider.overrideWithValue(
            ready
                ? const AiReadiness.ready(AiRoute.chatgptPlan)
                : const AiReadiness.off(),
          ),
          aiGatewayProvider.overrideWithValue(ready ? ai : null),
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
    return (revealed: revealed);
  }

  final field = find.byKey(const ValueKey('search-field'));
  final panel = find.byKey(const ValueKey('ai-ask-panel'));

  Future<void> type(WidgetTester tester, String q) async {
    await tester.enterText(field, q);
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, {bool settle = true}) async {
    await tester.testTextInput.receiveAction(TextInputAction.send);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Map<String, dynamic> sentInput() =>
      jsonDecode(ai.calls.last.input) as Map<String, dynamic>;

  /// 보낸 번호 — 제목으로 찾는다.
  int nOf(String title) =>
      (sentInput()['todos'] as List).cast<Map<String, dynamic>>().firstWhere(
            (t) => t['t'] == title,
          )['n']
          as int;

  ProviderContainer container(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(
      find.byKey(const ValueKey('open-search'), skipOffstage: false),
    ),
  );

  group('데스크탑 오버레이', () {
    testWidgets('준비되면 빈 화면에 "? 로 시작하면" 안내', (tester) async {
      await mount(tester);
      expect(find.textContaining('? 로 시작하면 AI 에게 물어봐요'), findsOneWidget);
    });

    testWidgets('? 로 시작하면 검색 대신 물어보기 — 입력 중엔 보내지 않는다', (tester) async {
      await mount(tester);
      await type(tester, '?회의 언제');
      expect(panel, findsOneWidget);
      expect(find.byKey(const ValueKey('ai-ask-idle')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-filter-done')), findsNothing);
      expect(find.byKey(const ValueKey('search-hit-a')), findsNothing);
      expect(find.text('Enter 물어보기 · ↑↓ 인용 고르기 · Esc 닫기'), findsOneWidget);
      expect(ai.calls, isEmpty, reason: 'Enter 를 눌러야만 보낸다');
    });

    testWidgets('Enter → 답이 흘러 들어오고, 보낸 n 만 칩·없는 n 은 본문에서 지움', (tester) async {
      final m = await mount(tester);
      await type(tester, '?회의 언제');
      // 응답은 보낸 입력을 보고 만들어야 하므로 n 은 첫 호출 뒤에 안다 — 순서가 고정이라
      // 직렬화 규칙(트리 + sortOrder → createdAt → id)대로 a=1, b=2.
      ai.streamChunks.addAll(['회의 준비 [#1] 가 먼저', '예요. 지어낸 일 [#9', '9].']);
      await send(tester);

      expect(sentInput()['question'], '회의 언제');
      expect(nOf('회의 준비'), 1);
      final answer = tester.widget<Text>(
        find.byKey(const ValueKey('ai-ask-answer')),
      );
      expect(answer.data, '회의 준비 [1] 가 먼저예요. 지어낸 일.');
      expect(find.byKey(const ValueKey('ai-ask-cite-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-ask-cite-b')), findsNothing);
      expect(find.byKey(const ValueKey('ai-ask-footnote')), findsOneWidget);

      // 칩 → 셸의 그 위치로(오버레이 닫힘). 질문은 최근 검색에 남지 않는다.
      await tester.tap(find.byKey(const ValueKey('ai-ask-cite-a')));
      await tester.pumpAndSettle();
      expect(m.revealed, ['a']);
      expect(find.byKey(const ValueKey('search-overlay')), findsNothing);
      expect(container(tester).read(recentSearchesProvider), isEmpty);
      expect(prefs.lists[RecentSearchesNotifier.storageKey], isNull);
    });

    testWidgets('↓ 로 칩을 고르고 Enter 로 연다', (tester) async {
      final m = await mount(tester);
      await type(tester, '?뭐 해');
      ai.streamChunks.addAll(['회의 [#1], 결제 [#2]']);
      await send(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await send(tester);
      expect(m.revealed, ['b']);
      expect(ai.calls, hasLength(1), reason: '칩을 골라 둔 Enter 는 다시 묻지 않는다');
    });

    testWidgets('쓰기 0회 — 묻고 칩을 열어도 저장소를 건드리지 않는다', (tester) async {
      await mount(tester);
      await type(tester, '?정리해줘');
      ai.streamChunks.addAll(['회의 준비 [#1] 결제 [#2]']);
      await send(tester);
      await tester.tap(find.byKey(const ValueKey('ai-ask-cite-b')));
      await tester.pumpAndSettle();
      expect(repo.upserts, 0);
      expect(repo.deletes, 0);
    });

    testWidgets('보낸 입력 — 보관 카테고리·15일 전 완료 제외, 설명 포함', (tester) async {
      await mount(
        tester,
        items: [
          ...todos,
          make('arch', title: '보관된 일', category: Category.daily),
          make('old', title: '오래전 완료', doneAt: DateTime(2026, 9, 25, 10)),
          make('recent', title: '최근 완료', doneAt: DateTime(2026, 10, 8, 10)),
        ],
        archived: {Category.daily.id},
      );
      await type(tester, '?뭐 했지');
      await send(tester);
      final titles = [
        for (final t in (sentInput()['todos'] as List).cast<Map>()) t['t'],
      ];
      expect(titles, containsAll(['회의 준비', '결제 모듈 리뷰', '최근 완료']));
      expect(titles, isNot(contains('보관된 일')));
      expect(titles, isNot(contains('오래전 완료')));
      final a = (sentInput()['todos'] as List).cast<Map>().firstWhere(
        (t) => t['t'] == '회의 준비',
      );
      expect(a['desc'], '안건 세 개 정리');
    });

    testWidgets('설명 보내기를 끄면 desc 가 없다', (tester) async {
      prefs.lists['ai.sendDescription'] = ['false'];
      await mount(tester);
      await type(tester, '?뭐 해');
      await send(tester);
      final sent = (sentInput()['todos'] as List).cast<Map>();
      expect(sent.any((t) => t.containsKey('desc')), isFalse);
    });

    testWidgets('스트림 실패 → 안내 한 줄', (tester) async {
      await mount(tester);
      await type(tester, '?뭐 해');
      ai.streamError = Exception('boom');
      await send(tester);
      expect(find.byKey(const ValueKey('ai-inline-error')), findsOneWidget);
    });

    testWidgets('그사이 지워진 항목 칩은 열지 않고 안내', (tester) async {
      final m = await mount(tester);
      await type(tester, '?뭐 해');
      ai.streamChunks.addAll(['결제 [#2]']);
      await send(tester);
      todosStream.add([todos.first]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-ask-cite-b')));
      await tester.pump();
      expect(find.text('지워진 항목이에요'), findsOneWidget);
      expect(m.revealed, isEmpty);
    });

    testWidgets('Esc 로 닫으면 흐르던 답 구독을 취소한다', (tester) async {
      await mount(tester);
      await type(tester, '?뭐 해');
      ai.hold = Completer<void>();
      await send(tester, settle: false);
      expect(find.byKey(const ValueKey('ai-ask-loading')), findsOneWidget);
      expect(ai.streamCancelled, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('search-overlay')), findsNothing);
      expect(ai.streamCancelled, isTrue);
    });

    testWidgets('? 를 지워 검색으로 돌아가면 구독 취소', (tester) async {
      await mount(tester);
      await type(tester, '?회의');
      ai.hold = Completer<void>();
      await send(tester, settle: false);
      await tester.enterText(field, '회의');
      await tester.pump();
      expect(ai.streamCancelled, isTrue);
      expect(panel, findsNothing);
      expect(find.byKey(const ValueKey('search-hit-a')), findsOneWidget);
    });

    testWidgets('새 질문을 보내면 앞 질문 구독 취소', (tester) async {
      await mount(tester);
      await type(tester, '?첫 질문');
      ai.hold = Completer<void>();
      await send(tester, settle: false);
      await tester.enterText(field, '?둘째 질문');
      await tester.pump();
      expect(ai.streamCancelled, isFalse, reason: '입력만으로는 끊지 않는다');
      await send(tester, settle: false);
      expect(ai.streamCancelled, isTrue);
      expect(ai.calls, hasLength(2));
    });

    testWidgets('준비 안 됐으면 ? 는 평범한 검색어 + 안내 한 줄', (tester) async {
      await mount(
        tester,
        ready: false,
        items: [
          ...todos,
          make('q', title: '?표 들어간 제목'),
        ],
      );
      expect(find.textContaining('? 로 시작하면'), findsNothing);
      await type(tester, '?표');
      expect(panel, findsNothing);
      expect(find.byKey(const ValueKey('search-hit-q')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-ask-unavailable')), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(ai.calls, isEmpty);
    });
  });

  group('폰', () {
    testWidgets('[검색 | 물어보기] — 물어보기로 묻고 칩을 누르면 상세', (tester) async {
      await mount(tester, form: FormFactor.mobile);
      expect(find.byKey(const ValueKey('search-mode')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-filter-done')), findsOneWidget);

      await tester.tap(find.text('물어보기'));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(find.byKey(const ValueKey('search-filter-done')), findsNothing);

      await type(tester, '회의 언제야');
      expect(ai.calls, isEmpty);
      ai.streamChunks.addAll(['회의 준비 [#1]']);
      await send(tester);
      expect(sentInput()['question'], '회의 언제야');

      await tester.tap(find.byKey(const ValueKey('ai-ask-cite-a')));
      await tester.pumpAndSettle();
      expect(find.byType(TodoDetailScreen), findsOneWidget);
      expect(repo.upserts, 0);
      expect(repo.deletes, 0);
      expect(container(tester).read(recentSearchesProvider), isEmpty);
    });

    testWidgets('폰도 ? 접두사를 받고, [검색] 을 누르면 ? 를 떼고 검색', (tester) async {
      await mount(tester, form: FormFactor.mobile);
      await type(tester, '?회의');
      expect(panel, findsOneWidget);
      await tester.tap(find.text('검색').first);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(find.byKey(const ValueKey('search-hit-a')), findsOneWidget);
    });

    testWidgets('준비 안 됐으면 세그먼트가 없다', (tester) async {
      await mount(tester, form: FormFactor.mobile, ready: false);
      expect(find.byKey(const ValueKey('search-mode')), findsNothing);
    });
  });
}
