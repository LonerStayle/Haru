import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_controller.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_readiness.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
import 'package:solo_todo/src/features/calendar/calendar_service.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

import '../ai/fake_ai_gateway.dart';

/// T2 — 일괄 추가 대화상자의 [AI로 정리].
void main() {
  late FakeAiGateway ai;
  final now = DateTime(2026, 10, 10, 9);
  const pasted = '회의록\n- 다음 주 금요일까지 보고서 제출\n- 디자인 시안 검토\n  - 색상\n  - 폰트';

  setUp(() => ai = FakeAiGateway());

  Map<String, dynamic> item(
    String title, {
    String? categoryId,
    String? date,
    String? dateEvidence,
    List<String> children = const [],
  }) => {
    'title': title,
    'categoryId': categoryId,
    'date': date,
    'time': null,
    'timeAnchor': 'start',
    'dateEvidence': dateEvidence,
    'evidence': null,
    'children': [
      for (final c in children) {'title': c, 'evidence': null},
    ],
  };

  Future<List<AddTodoSubmission>> mount(
    WidgetTester tester, {
    bool ready = true,
    String? parentId,
    FormFactor form = FormFactor.desktop,
  }) async {
    AppPlatform.debugFormFactorOverride = form;
    addTearDown(() => AppPlatform.debugFormFactorOverride = null);
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final submissions = <AddTodoSubmission>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          uiPrefsStoreProvider.overrideWithValue(MemoryUiPrefsStore()),
          aiReadinessProvider.overrideWithValue(
            ready
                ? const AiReadiness.ready(AiRoute.chatgptPlan)
                : const AiReadiness.off(),
          ),
          aiGatewayProvider.overrideWithValue(ready ? ai : null),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AddTodoSheet(
                initialCategory: Category.daily,
                now: () => now,
                parentId: parentId,
                onSubmit: submissions.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return submissions;
  }

  Future<void> paste(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      pasted,
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('AI 준비 전엔 [AI로 정리] 가 없고 기존 두 버튼 그대로', (tester) async {
    await mount(tester, ready: false);
    await paste(tester);
    expect(find.byKey(const ValueKey('bulk-paste-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-paste-ai')), findsNothing);
    expect(find.byKey(const ValueKey('bulk-paste-confirm')), findsOneWidget);
  });

  testWidgets('초안 → 체크 해제 제외 · 카테고리 · 근거 날짜 · 하위 1단계', (tester) async {
    final subs = await mount(tester);
    ai.jsonQueue.add({
      'items': [
        item(
          '보고서 제출',
          categoryId: 'work',
          date: '2026-10-16',
          dateEvidence: '다음 주 금요일까지',
        ),
        item('디자인 시안 검토', categoryId: 'ghost', children: ['색상', '폰트']),
        item('버릴 항목', date: '2026-10-11', dateEvidence: '내일'),
      ],
    });
    await paste(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-paste-ai')));
    await tester.pumpAndSettle();

    expect(find.text('보고서 제출'), findsOneWidget);
    expect(find.text('5건 추가'), findsOneWidget);
    // 원문에 없는 근거('내일')로 만든 날짜는 칩이 없다.
    expect(find.byKey(const ValueKey('ai-paste-date-2')), findsNothing);
    // 세 번째 항목 빼기, 두 번째의 '폰트' 하위 빼기.
    await tester.tap(find.byKey(const ValueKey('ai-paste-check-2')));
    await tester.tap(find.byKey(const ValueKey('ai-paste-child-1-1')));
    await tester.pump();
    expect(find.text('3건 추가'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-paste-confirm')));
    await tester.pumpAndSettle();

    expect(subs.map((s) => s.title), ['보고서 제출', '디자인 시안 검토']);
    expect(subs.every((s) => s.fromAi), isTrue);
    expect(subs[0].category, Category.work);
    expect(subs[0].dueAt, DateTime(2026, 10, 16));
    expect(subs[0].isAllDay, isTrue);
    expect(subs[0].recurrence, isNull);
    // 모르는 카테고리 → 시트 기본(daily).
    expect(subs[1].category, Category.daily);
    expect(subs[1].dueAt, isNull);
    expect(subs[1].children.map((c) => c.title), ['색상']);

    final input = ai.calls.single.input;
    expect(input, contains('"today":"2026-10-10(토)"'));
    expect(input, contains('"categories"'));
  });

  testWidgets('날짜 칩 ✕ 로 날짜를 빼고 추가', (tester) async {
    final subs = await mount(tester);
    ai.jsonQueue.add({
      'items': [item('보고서 제출', date: '2026-10-16', dateEvidence: '다음 주 금요일까지')],
    });
    await paste(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-paste-ai')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('ai-paste-date-0')),
        matching: find.byIcon(Icons.clear),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-paste-confirm')));
    await tester.pumpAndSettle();
    expect(subs.single.dueAt, isNull);
  });

  testWidgets('패널 취소 → 저장 0건, 제목은 붙여넣기 전으로', (tester) async {
    final subs = await mount(tester);
    ai.jsonQueue.add({
      'items': [item('보고서 제출')],
    });
    await paste(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-paste-ai')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-paste-cancel')));
    await tester.pumpAndSettle();
    expect(subs, isEmpty);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('add-todo-title')),
    );
    expect(field.controller!.text, '');
  });

  testWidgets('응답이 없으면 안내 + [줄마다 그냥 추가] 를 눌러야만 기존 일괄 추가', (tester) async {
    final subs = await mount(tester);
    await paste(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-paste-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-inline-error')), findsOneWidget);
    expect(subs, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-paste-plain')));
    await tester.pumpAndSettle();
    expect(subs.map((s) => s.title), [
      '회의록',
      '다음 주 금요일까지 보고서 제출',
      '디자인 시안 검토',
      '색상',
      '폰트',
    ]);
    expect(subs.any((s) => s.fromAi), isFalse);
  });

  testWidgets('하위 추가 모드 — 카테고리 칩 없음, 카테고리를 보내지 않음', (tester) async {
    final subs = await mount(tester, parentId: 'p');
    ai.jsonQueue.add({
      'items': [item('보고서 제출', categoryId: 'work')],
    });
    await paste(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-paste-ai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-paste-category-0')), findsNothing);
    expect(ai.calls.single.input, isNot(contains('"categories"')));
    await tester.tap(find.byKey(const ValueKey('ai-paste-confirm')));
    await tester.pumpAndSettle();
    expect(subs.single.parentId, 'p');
    expect(subs.single.category, Category.daily);
  });

  testWidgets('폰은 아래 시트로 같은 초안', (tester) async {
    final subs = await mount(tester, form: FormFactor.mobile);
    ai.jsonQueue.add({
      'items': [item('보고서 제출')],
    });
    await paste(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-paste-ai')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-paste-confirm')));
    await tester.pumpAndSettle();
    expect(subs.single.title, '보고서 제출');
  });

  group('저장 — 한 번에 되돌리기', () {
    late AppDatabase db;
    late LocalTodoRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = LocalTodoRepository(db.todosDao);
    });
    tearDown(() async => db.close());

    testWidgets('AI 제출은 부모·하위를 만들고 되돌리기로 전부 지운다', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            todoRepositoryProvider.overrideWithValue(repo),
            nowProvider.overrideWithValue(() => now),
            calendarServiceProvider.overrideWithValue(null),
            uiPrefsStoreProvider.overrideWithValue(MemoryUiPrefsStore()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => savePendingSubmissions(context, ref, [
                    const AddTodoSubmission(
                      title: '부모',
                      category: Category.work,
                      dueAt: null,
                      addToCalendar: false,
                      fromAi: true,
                      children: [
                        AddTodoSubmission(
                          title: '하위',
                          category: Category.work,
                          dueAt: null,
                          addToCalendar: false,
                        ),
                      ],
                    ),
                  ]),
                  child: const Text('저장'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      final all = await db.select(db.todos).get();
      expect(all.map((t) => t.title).toSet(), {'부모', '하위'});
      expect(find.text('2건 추가했어요.'), findsOneWidget);

      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(await db.select(db.todos).get(), isEmpty);
    });
  });
}
