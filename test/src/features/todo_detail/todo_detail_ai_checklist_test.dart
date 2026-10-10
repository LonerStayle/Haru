import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:solo_todo/src/features/ai/ai_providers.dart';
import 'package:solo_todo/src/features/ai/ai_readiness.dart';
import 'package:solo_todo/src/features/ai/ai_route.dart';
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

/// T1 — 상세 설명 아래 "목록으로" AI 칩.
void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  late FakeAiGateway ai;
  final now = DateTime.utc(2026, 5, 30, 9);
  const long =
      '이번 주 안에 처리해야 함. 먼저 로그를 모으고, 그 다음 원인을 정리해서 공유한다. 끝나면 회고 문서에 남긴다. 배경 설명이 좀 더 길게 붙어 있다.';
  const answer = {
    'intro': '이번 주 안에 처리해야 함.',
    'items': ['로그 모으기', '원인 정리해서 공유', '회고 문서에 남기기'],
  };

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    ai = FakeAiGateway();
  });
  tearDown(() async => db.close());

  Todo make(String id, {String? description, DateTime? doneAt}) => Todo(
    id: id,
    title: '제목-$id',
    description: description,
    category: Category.work,
    createdAt: now,
    updatedAt: now,
    doneAt: doneAt,
    sortOrder: 7,
  );

  Future<StreamController<List<Todo>>> mount(
    WidgetTester tester,
    Todo parent, {
    bool ready = true,
  }) async {
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
            yield [parent];
            yield* stream.stream;
          }),
          childrenOfProvider.overrideWith((_, pid) => Stream.value([])),
          groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
          aiReadinessProvider.overrideWithValue(
            ready
                ? const AiReadiness.ready(AiRoute.chatgptPlan)
                : const AiReadiness.off(),
          ),
          aiGatewayProvider.overrideWithValue(ready ? ai : null),
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

  final chip = find.byKey(const ValueKey('detail-ai-checklist'));

  testWidgets('설명이 짧으면 칩이 없다', (tester) async {
    await mount(tester, make('short', description: '짧은 설명'));
    expect(chip, findsNothing);
  });

  testWidgets('완료한 할 일엔 칩이 없다', (tester) async {
    await mount(tester, make('done', description: long, doneAt: now));
    expect(chip, findsNothing);
  });

  testWidgets('AI 준비 전엔 칩이 없다', (tester) async {
    await mount(tester, make('off', description: long), ready: false);
    expect(chip, findsNothing);
  });

  testWidgets('누르면 설명이 목록으로, 순서 그대로, 되돌리기로 원복', (tester) async {
    final p = make('p', description: long);
    await repo.upsert(p);
    final stream = await mount(tester, p);
    ai.jsonQueue.add(answer);

    await tester.tap(chip);
    await tester.pumpAndSettle();

    final saved = (await repo.getById('p'))!;
    expect(
      saved.description,
      '이번 주 안에 처리해야 함.\n\n- [ ] 로그 모으기\n- [ ] 원인 정리해서 공유\n- [ ] 회고 문서에 남기기',
    );
    expect(saved.sortOrder, 7, reason: '구조 변환은 자리를 바꾸지 않는다');
    expect(find.text('설명을 목록 3개로 바꿨어요.'), findsOneWidget);
    expect(ai.calls.single.input, contains('먼저 로그를 모으고'));

    // 목록이 되면 기존 "하위 항목으로" 제안이 뜬다.
    stream.add([saved]);
    await tester.pumpAndSettle();
    expect(find.text('설명에 목록 3개가 있어요'), findsOneWidget);
    expect(chip, findsNothing);

    // 그사이 제목을 고쳐도 되돌리기는 설명만 돌린다.
    await repo.upsert(saved.copyWith(title: '새 제목'));
    await tester.tap(find.text('되돌리기'));
    await tester.pumpAndSettle();
    final back = (await repo.getById('p'))!;
    expect(back.description, long);
    expect(back.title, '새 제목');
  });

  testWidgets('기다리는 사이 설명을 고쳤으면 적용하지 않는다', (tester) async {
    final p = make('p', description: long);
    await repo.upsert(p);
    await mount(tester, p);
    ai.hold = Completer<void>();
    ai.jsonQueue.add(answer);

    await tester.tap(chip);
    await tester.pump();
    expect(find.text('목록으로 정리 중…'), findsOneWidget);

    await repo.upsert(p.copyWith(description: '$long 추가'));
    ai.hold!.complete();
    await tester.pumpAndSettle();

    expect((await repo.getById('p'))!.description, '$long 추가');
    expect(find.text('설명이 바뀌어 적용하지 않았어요.'), findsOneWidget);
  });

  testWidgets('응답이 없으면 안내 한 줄, 데이터는 그대로', (tester) async {
    final p = make('p', description: long);
    await repo.upsert(p);
    await mount(tester, p);

    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-inline-error')), findsOneWidget);
    expect((await repo.getById('p'))!.description, long);
  });
}
