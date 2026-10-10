import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/calendar_aware_todo_repository.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/data/todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_readiness.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
import 'package:solo_todo/src/features/backlog/stale_backlog_screen.dart';
import 'package:solo_todo/src/features/calendar/calendar_settings.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

import '../ai/fake_ai_gateway.dart';

/// T3 — 오래된 할 일 [제안 받기] + 행별 칩.
void main() {
  late AppDatabase db;
  late LocalTodoRepository local;
  late FakeAiGateway ai;
  late MemoryUiPrefsStore prefs;
  var tick = 0;
  final now = DateTime(2026, 9, 25, 10);

  setUp(() {
    db = AppDatabase.memory();
    local = LocalTodoRepository(db.todosDao);
    ai = FakeAiGateway();
    prefs = MemoryUiPrefsStore();
    tick = 0;
  });
  tearDown(() async {
    AppPlatform.debugFormFactorOverride = null;
    await db.close();
  });

  Todo make(
    String id,
    int ageDays, {
    String? parentId,
    Category category = Category.work,
    String? description,
    String? seriesId,
    int sortOrder = 0,
  }) {
    final created = now.subtract(Duration(days: ageDays));
    return Todo(
      id: id,
      title: '제목-$id',
      category: category,
      createdAt: created,
      updatedAt: created,
      parentId: parentId,
      description: description,
      seriesId: seriesId,
      sortOrder: sortOrder,
    );
  }

  Future<void> mount(
    WidgetTester tester,
    List<Todo> all, {
    bool ready = true,
    TodoRepository? repo,
    List<Category> categories = Category.builtinSeeds,
  }) async {
    final target = repo ?? local;
    for (final t in all) {
      await target.upsert(t);
    }
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(
            () => now.add(Duration(seconds: tick++)),
          ),
          todoRepositoryProvider.overrideWithValue(target),
          allTodosProvider.overrideWith((_) => Stream.value(all)),
          categoriesProvider.overrideWith((_) => Stream.value(categories)),
          groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
          uiPrefsStoreProvider.overrideWithValue(prefs),
          aiReadinessProvider.overrideWithValue(
            ready
                ? const AiReadiness.ready(AiRoute.chatgptPlan)
                : const AiReadiness.off(),
          ),
          aiGatewayProvider.overrideWithValue(ready ? ai : null),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const StaleBacklogScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> answer(List<(int, String, String)> rows) => {
    'suggestions': [
      for (final (n, action, reason) in rows)
        {'n': n, 'action': action, 'reason': reason},
    ],
  };

  /// 보낸 입력의 항목들 — 제목으로 n 을 찾는다.
  List<Map<String, dynamic>> sentItems([int call = 0]) => [
    for (final e
        in (jsonDecode(ai.calls[call].input) as Map<String, dynamic>)['items']
            as List)
      e as Map<String, dynamic>,
  ];

  Future<void> suggest(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('stale-ai-suggest')));
    await tester.pumpAndSettle();
  }

  Finder chip(String id) => find.byKey(ValueKey('stale-ai-chip-$id'));

  testWidgets('준비 안 됐으면 [제안 받기] 가 없다', (tester) async {
    await mount(tester, [make('a', 100)], ready: false);
    expect(find.byKey(const ValueKey('stale-ai-suggest')), findsNothing);
    expect(find.byKey(const ValueKey('stale-select-all')), findsOneWidget);
  });

  testWidgets('제안 → 행마다 칩·근거, 보낸 입력엔 최상위·활성·비반복만', (tester) async {
    ai.jsonQueue.add(
      answer([(1, 'nextMonth', '미뤄도 되는 개선'), (2, 'keep', '근거 부족')]),
    );
    final hold = ai.hold = Completer<void>();
    await mount(
      tester,
      [
        make('a', 100, description: '설명-a'),
        make('a1', 100, parentId: 'a'),
        make('arch', 90, category: Category.daily),
        make('rep', 80, seriesId: 'S'),
        make('b', 40),
      ],
      categories: [
        for (final c in Category.builtinSeeds)
          c.id == Category.daily.id ? c.copyWith(archived: true) : c,
      ],
    );
    await tester.tap(find.byKey(const ValueKey('stale-ai-suggest')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('stale-ai-loading')), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('stale-ai-suggest')))
          .onPressed,
      isNull,
      reason: '응답을 기다리는 동안 다시 보내지 않는다',
    );
    hold.complete();
    await tester.pumpAndSettle();

    final sent = sentItems();
    expect(sent.map((e) => e['t']), ['제목-a', '제목-b']);
    expect(sent.first['kids'], 1);
    expect(sent.first['age'], 100);
    expect(sent.first['desc'], '설명-a', reason: '설명 전송 기본 켬');

    expect(find.byKey(const ValueKey('stale-ai-loading')), findsNothing);
    expect(
      find.descendant(of: chip('a'), matching: find.text('다음 달')),
      findsOneWidget,
    );
    expect(find.text('미뤄도 되는 개선'), findsOneWidget);
    expect(
      find.descendant(of: chip('b'), matching: find.text('유지')),
      findsOneWidget,
    );
    // 아무것도 바뀌지 않았다.
    expect((await local.getById('a'))!.dueAt, isNull);
    expect(
      (await local.getById(
        'a',
      ))!.updatedAt.isAtSameMomentAs(make('a', 100).updatedAt),
      isTrue,
    );

    // '유지' 는 칩을 치우기만 한다.
    await tester.tap(chip('b'));
    await tester.pumpAndSettle();
    expect(chip('b'), findsNothing);
    expect(
      (await local.getById(
        'b',
      ))!.updatedAt.isAtSameMomentAs(make('b', 40).updatedAt),
      isTrue,
    );
  });

  testWidgets('설명 전송을 꺼 두면 desc 를 보내지 않는다', (tester) async {
    prefs.lists['ai.sendDescription'] = ['false'];
    ai.jsonQueue.add(answer([(1, 'keep', '')]));
    await mount(tester, [make('a', 100, description: '비밀 메모')]);
    await suggest(tester);
    expect(sentItems().single.containsKey('desc'), isFalse);
    expect(ai.calls.single.input, isNot(contains('비밀 메모')));
  });

  testWidgets('완료 추정은 두 번 눌러야 — 1회는 불변, 2회 완료 + 되돌리기', (tester) async {
    ai.jsonQueue.add(answer([(1, 'done', '배포 완료라고 적힘')]));
    await mount(tester, [make('a', 100)]);
    await suggest(tester);

    await tester.tap(chip('a'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.isDone, isFalse);
    expect(
      find.descendant(of: chip('a'), matching: find.text('완료할까요?')),
      findsOneWidget,
    );

    // 4초가 지나면 확인이 풀린다 — 다시 한 번으로는 완료되지 않는다.
    await tester.pump(const Duration(seconds: 5));
    expect(
      find.descendant(of: chip('a'), matching: find.text('완료 추정')),
      findsOneWidget,
    );
    await tester.tap(chip('a'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.isDone, isFalse);

    await tester.tap(chip('a'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.isDone, isTrue);
    expect(chip('a'), findsNothing, reason: '적용한 제안은 지운다');

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.isDone, isFalse);
  });

  testWidgets('다음 달 → 다음 달 1일 종일, 순서 그대로, 캘린더에 새로 올리지 않음', (tester) async {
    final cal = CalendarAwareTodoRepository(
      inner: local,
      ops: db.calendarOpsDao,
      settings: () => const CalendarSettings(
        connected: true,
        writeCalendarId: 'write@cal',
        defaultAddToCalendar: true,
      ),
    );
    ai.jsonQueue.add(answer([(1, 'nextMonth', '미뤄도 됨')]));
    await mount(tester, [make('a', 100, sortOrder: 7)], repo: cal);
    await suggest(tester);
    await tester.tap(chip('a'));
    await tester.pumpAndSettle();

    final a = (await local.getById('a'))!;
    expect(a.dueAt!.toLocal(), DateTime(2026, 10, 1));
    expect(a.isAllDay, isTrue);
    expect(a.sortOrder, 7);
    expect(await db.calendarOpsDao.dueOps(DateTime(2100)), isEmpty);

    // 대조 — 이 조립에서 의사 없이 날짜를 붙이면 큐에 쌓인다.
    await cal.upsert(make('ctl', 1).copyWith(dueAt: DateTime(2026, 10, 2)));
    expect(await db.calendarOpsDao.dueOps(DateTime(2100)), isNotEmpty);

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.dueAt, isNull);
  });

  testWidgets('장기 목표로 → 하위까지 카테고리 이동, 되돌리기로 원래대로', (tester) async {
    ai.jsonQueue.add(answer([(1, 'longterm', '학습 과제')]));
    await mount(tester, [make('a', 100), make('a1', 100, parentId: 'a')]);
    await suggest(tester);
    expect(
      find.descendant(of: chip('a'), matching: find.text('장기 목표로')),
      findsOneWidget,
    );
    await tester.tap(chip('a'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.category.id, Category.longterm.id);
    expect((await local.getById('a1'))!.category.id, Category.longterm.id);
    expect(chip('a'), findsNothing);

    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    expect((await local.getById('a'))!.category.id, Category.work.id);
    expect((await local.getById('a1'))!.category.id, Category.work.id);
  });

  testWidgets('장기 목표 카테고리가 보관됐으면 longterm 제안은 유지로', (tester) async {
    ai.jsonQueue.add(answer([(1, 'longterm', '학습 과제')]));
    await mount(
      tester,
      [make('a', 100)],
      categories: [
        for (final c in Category.builtinSeeds)
          c.id == Category.longterm.id ? c.copyWith(archived: true) : c,
      ],
    );
    await suggest(tester);
    expect(
      find.descendant(of: chip('a'), matching: find.text('유지')),
      findsOneWidget,
    );
  });

  testWidgets('칩을 적용해도 선택해 둔 다른 항목은 그대로 선택돼 있다', (tester) async {
    ai.jsonQueue.add(answer([(1, 'nextWeek', '곧 해야 함')]));
    await mount(tester, [make('a', 100), make('b', 40)]);
    await tester.tap(find.byKey(const ValueKey('stale-select-b')));
    await tester.pumpAndSettle();
    await suggest(tester);

    await tester.tap(chip('a'));
    await tester.pumpAndSettle();
    expect(
      (await local.getById('a'))!.dueAt!.toLocal(),
      DateTime(2026, 9, 28),
      reason: '다음 주 월요일',
    );
    expect(
      tester
          .widget<Checkbox>(find.byKey(const ValueKey('stale-select-b')))
          .value,
      isTrue,
    );
    expect(find.text('완료 1'), findsOneWidget);
  });

  testWidgets('응답에 없는 n·목록 밖 action 은 무시', (tester) async {
    ai.jsonQueue.add({
      'suggestions': [
        {'n': 9, 'action': 'done', 'reason': '없는 번호'},
        {'n': 1, 'action': 'delete', 'reason': '삭제 제안'},
        {'n': 2, 'action': 'nextWeek', 'reason': '곧'},
      ],
    });
    await mount(tester, [make('a', 100), make('b', 40)]);
    await suggest(tester);
    expect(chip('a'), findsNothing);
    expect(find.text('삭제 제안'), findsNothing);
    expect(chip('b'), findsOneWidget);
  });

  testWidgets('응답 실패 → 안내 한 줄, 데이터 불변', (tester) async {
    ai.jsonQueue.add(null);
    await mount(tester, [make('a', 100)]);
    await suggest(tester);
    expect(find.byKey(const ValueKey('ai-inline-error')), findsOneWidget);
    expect(chip('a'), findsNothing);
    expect(
      (await local.getById(
        'a',
      ))!.updatedAt.isAtSameMomentAs(make('a', 100).updatedAt),
      isTrue,
    );
  });

  testWidgets('폰 — 아이콘 버튼으로 같은 제안·칩', (tester) async {
    AppPlatform.debugFormFactorOverride = FormFactor.mobile;
    ai.jsonQueue.add(answer([(1, 'nextMonth', '미뤄도 됨')]));
    await mount(tester, [make('a', 100)]);
    expect(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.key == const ValueKey('stale-ai-suggest'),
      ),
      findsOneWidget,
    );
    await suggest(tester);
    expect(chip('a'), findsOneWidget);
    expect(find.text('미뤄도 됨'), findsOneWidget);
  });
}
