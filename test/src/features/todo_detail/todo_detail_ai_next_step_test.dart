import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_readiness.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
import 'package:solo_todo/src/features/calendar/calendar_providers.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';

import '../ai/fake_ai_gateway.dart';

class _SortStore implements SortModePreference {
  @override
  Future<TodoSortMode> load() async => TodoSortMode.manual;

  @override
  Future<void> save(TodoSortMode mode) async {}
}

/// T4 — 장기 목표·아이디어 상세의 "다음 한 걸음" 카드.
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  late FakeAiGateway ai;
  late List<bool> intents;
  late StreamController<List<Todo>> allStream;
  late StreamController<List<Todo>> childStream;
  final now = DateTime.utc(2026, 5, 30, 9);
  const answer = {
    'steps': [
      {'title': '경쟁 앱 3개 스크린샷 모으기', 'minutes': 20, 'why': '방향 잡기'},
      {'title': '첫 화면 스케치하기', 'minutes': 25, 'why': '바로 만들기'},
      {'title': '이름 후보 정하기', 'minutes': 10, 'why': '결정하기'},
    ],
  };

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    ai = FakeAiGateway();
    intents = [];
    allStream = StreamController<List<Todo>>.broadcast();
    childStream = StreamController<List<Todo>>.broadcast();
  });
  tearDown(() async {
    await allStream.close();
    await childStream.close();
    await db.close();
  });

  Todo make(
    String id, {
    Category category = Category.idea,
    String? parentId,
    DateTime? doneAt,
    String? seriesId,
  }) => Todo(
    id: id,
    title: '제목-$id',
    category: category,
    createdAt: now,
    updatedAt: now,
    parentId: parentId,
    doneAt: doneAt,
    seriesId: seriesId,
  );

  Future<List<Todo>> rowsInDb() async {
    final rows = await db.select(db.todos).get();
    return [for (final r in rows) (await repo.getById(r.id))!];
  }

  Future<List<Todo>> childrenInDb(String pid) async =>
      (await rowsInDb()).where((t) => t.parentId == pid).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  /// 저장소 내용을 목록 스트림으로 흘려 화면에 반영한다(실제 앱의 drift watch 대신).
  Future<void> sync(WidgetTester tester, String pid) async {
    allStream.add(await rowsInDb());
    childStream.add(await childrenInDb(pid));
    await tester.pumpAndSettle();
  }

  List<Override> overrides(
    List<Todo> all,
    String pid, {
    List<Todo> children = const [],
    bool ready = true,
  }) => [
    nowProvider.overrideWithValue(() => now),
    todoRepositoryProvider.overrideWithValue(repo),
    sortModePreferenceProvider.overrideWithValue(_SortStore()),
    allTodosProvider.overrideWith((_) async* {
      yield all;
      yield* allStream.stream;
    }),
    childrenOfProvider.overrideWith((_, id) async* {
      if (id != pid) {
        yield const <Todo>[];
        return;
      }
      yield children;
      yield* childStream.stream;
    }),
    groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
    calendarIntentProvider.overrideWithValue(intents.add),
    aiReadinessProvider.overrideWithValue(
      ready
          ? const AiReadiness.ready(AiRoute.chatgptPlan)
          : const AiReadiness.off(),
    ),
    aiGatewayProvider.overrideWithValue(ready ? ai : null),
  ];

  Future<void> mount(
    WidgetTester tester,
    Todo parent, {
    List<Todo>? all,
    List<Todo> children = const [],
    bool ready = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(
          all ?? [parent, ...children],
          parent.id,
          children: children,
          ready: ready,
        ),
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
  }

  final card = find.byKey(const ValueKey('detail-next-step-card'));
  final suggest = find.byKey(const ValueKey('detail-ai-next-step'));
  Finder add(int i) => find.byKey(ValueKey('next-step-add-$i'));
  Finder today(int i) => find.byKey(ValueKey('next-step-today-$i'));
  Finder added(int i) => find.byKey(ValueKey('next-step-added-$i'));

  group('카드가 없다', () {
    testWidgets('회사 할일 카테고리', (tester) async {
      await mount(tester, make('p', category: Category.work));
      expect(card, findsNothing);
    });

    testWidgets('하위가 이미 있음', (tester) async {
      final p = make('p');
      await mount(tester, p, children: [make('c', parentId: 'p')]);
      expect(card, findsNothing);
    });

    testWidgets('완료한 항목', (tester) async {
      await mount(tester, make('p', doneAt: now));
      expect(card, findsNothing);
    });

    testWidgets('반복 항목', (tester) async {
      await mount(tester, make('p', seriesId: 's'));
      expect(card, findsNothing);
    });

    testWidgets('AI 준비 전', (tester) async {
      await mount(tester, make('p'), ready: false);
      expect(card, findsNothing);
    });
  });

  testWidgets('장기 목표도 카드가 보이고, 제안 받기 → 3행 + 입력에 조상 경로', (tester) async {
    final root = make('root', category: Category.longterm);
    final p = make('p', category: Category.longterm, parentId: 'root');
    await mount(tester, p, all: [root, p]);
    expect(card, findsOneWidget);
    expect(find.text('다음 한 걸음'), findsOneWidget);

    ai.hold = Completer<void>();
    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pump();
    expect(find.text('제안 만드는 중…'), findsOneWidget);
    ai.hold!.complete();
    await tester.pumpAndSettle();

    expect(find.text('경쟁 앱 3개 스크린샷 모으기'), findsOneWidget);
    expect(find.text('약 25분 · 바로 만들기'), findsOneWidget);
    expect(add(2), findsOneWidget);
    expect(today(2), findsOneWidget);
    expect(suggest, findsNothing, reason: '결과가 있으면 다시 받기 버튼은 숨긴다');
    expect(ai.calls.single.input, contains('제목-root'));
    expect(ai.calls.single.input, contains(Category.longterm.label));
  });

  testWidgets('하위로 추가 → 부모·카테고리 상속, 날짜 없음, 캘린더 올리지 않음', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p);
    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pumpAndSettle();

    await tester.tap(add(0));
    await tester.pumpAndSettle();

    final kid = (await childrenInDb('p')).single;
    expect(kid.title, '경쟁 앱 3개 스크린샷 모으기');
    expect(kid.parentId, 'p');
    expect(kid.category.id, Category.idea.id);
    expect(kid.dueAt, isNull);
    expect(intents, [false]);
    expect(find.text('"경쟁 앱 3개 스크린샷 모으기" 하위로 추가했어요.'), findsOneWidget);
    expect(added(0), findsOneWidget);
    expect(add(0), findsNothing);
  });

  testWidgets('하위 + 오늘 → 로컬 자정·종일', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p);
    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pumpAndSettle();

    await tester.tap(today(1));
    await tester.pumpAndSettle();

    final kid = (await childrenInDb('p')).single;
    final l = now.toLocal();
    expect(kid.title, '첫 화면 스케치하기');
    expect(kid.dueAt!.toLocal(), DateTime(l.year, l.month, l.day));
    expect(kid.isAllDay, isTrue);
    expect(intents, [false]);
  });

  testWidgets('첫 추가로 하위가 생겨도 카드와 남은 제안이 그대로', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p);
    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pumpAndSettle();

    await tester.tap(add(0));
    await tester.pumpAndSettle();
    await sync(tester, 'p');

    expect(find.text('하위 항목 1'), findsOneWidget, reason: '하위 목록이 보인다');
    expect(card, findsOneWidget);
    expect(added(0), findsOneWidget);
    expect(add(1), findsOneWidget);
    expect(add(2), findsOneWidget);

    await tester.tap(today(2));
    await tester.pumpAndSettle();
    await sync(tester, 'p');
    expect((await childrenInDb('p')).map((t) => t.title), [
      '이름 후보 정하기',
      '경쟁 앱 3개 스크린샷 모으기',
    ], reason: '새 하위는 형제 맨 위');
  });

  testWidgets('되돌리기 → 그 하위만 삭제, 행은 다시 추가 가능', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p);
    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pumpAndSettle();

    await tester.tap(add(0));
    await tester.pumpAndSettle();
    await tester.tap(add(1));
    await tester.pumpAndSettle();
    expect((await childrenInDb('p')), hasLength(2));

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();

    expect((await childrenInDb('p')).map((t) => t.title), ['경쟁 앱 3개 스크린샷 모으기']);
    expect((await repo.getById('p')), isNotNull, reason: '부모는 그대로');
    expect(added(0), findsOneWidget);
    expect(add(1), findsOneWidget);
  });

  testWidgets('응답이 없으면 안내 한 줄, 0개면 "만들지 못했어요"', (tester) async {
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p);

    await tester.tap(suggest);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-inline-error')), findsOneWidget);
    expect(find.text('AI 응답을 받지 못했어요 · 설정에서 확인'), findsOneWidget);

    ai.jsonQueue.add({
      'steps': [
        {'title': '제목-p', 'minutes': 10, 'why': '부모와 같음'},
      ],
    });
    await tester.tap(suggest);
    await tester.pumpAndSettle();
    expect(find.text('제안을 만들지 못했어요.'), findsOneWidget);
    expect(await childrenInDb('p'), isEmpty);
  });

  testWidgets('폰 — 짧은 라벨, 같은 저장 경로', (tester) async {
    AppPlatform.debugFormFactorOverride = FormFactor.mobile;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    final p = make('p');
    await repo.upsert(p);
    await mount(tester, p);
    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pumpAndSettle();

    expect(find.text('하위로 추가'), findsNothing);
    expect(find.text('하위'), findsNWidgets(3));
    await tester.tap(today(0));
    await tester.pumpAndSettle();
    final kid = (await childrenInDb('p')).single;
    expect(kid.isAllDay, isTrue);
    expect(added(0), findsOneWidget);
  });

  testWidgets('인스펙터처럼 같은 자리에서 항목이 바뀌면 제안 초기화', (tester) async {
    final a = make('a');
    final b = make('b');
    final current = ValueNotifier<Todo>(a);
    addTearDown(current.dispose);
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        // 'none' — 어느 항목도 하위가 없다.
        overrides: overrides([a, b], 'none'),
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(
            body: ValueListenableBuilder<Todo>(
              valueListenable: current,
              builder: (_, parent, _) =>
                  TodoDetailView(parent: parent, onGone: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ai.jsonQueue.add(answer);
    await tester.tap(suggest);
    await tester.pumpAndSettle();
    expect(find.text('경쟁 앱 3개 스크린샷 모으기'), findsOneWidget);

    current.value = b;
    await tester.pumpAndSettle();
    expect(find.text('제목-b'), findsWidgets);
    expect(find.text('경쟁 앱 3개 스크린샷 모으기'), findsNothing);
    expect(suggest, findsOneWidget);
  });
}
