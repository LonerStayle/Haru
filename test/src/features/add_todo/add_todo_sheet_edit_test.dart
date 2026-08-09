import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// v1.2 — AddTodoSheet 의 edit 모드 검증.
///
/// initialTodo prefill (title / description / category / dueAt / type) + onUpdate
/// 콜백 호출 + dialog 닫힘.
void main() {
  Future<({List<AddTodoSubmission> submissions, List<Todo> updates})> mount(
    WidgetTester tester, {
    required Todo initialTodo,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final submissions = <AddTodoSubmission>[];
    final updates = <Todo>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          // J — 카테고리 칩 그룹핑용 groupsProvider watch. Drift timer leak 방지.
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AddTodoSheet(
              initialCategory: Category.daily,
              initialTodo: initialTodo,
              onSubmit: submissions.add,
              onUpdate: updates.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (submissions: submissions, updates: updates);
  }

  Todo makeInitial({
    String id = 'edit-1',
    String title = '회의 정리',
    String? description,
    Category category = const Category(
      id: 'work',
      label: '회사 할일',
      iconCodePoint: 0xef0a,
      colorValue: 0xFF2A66FF,
      sortOrder: 0,
      isBuiltin: true,
    ),
    TodoType type = TodoType.task,
  }) => Todo(
    id: id,
    title: title,
    category: category,
    dueAt: null,
    doneAt: null,
    createdAt: DateTime.utc(2026, 5, 28),
    updatedAt: DateTime.utc(2026, 5, 28),
    calendarEventId: null,
    description: description,
    type: type,
  );

  testWidgets('edit 모드 — title prefill + "할 일 편집" 헤더', (tester) async {
    final initial = makeInitial(title: '예전 제목');
    await mount(tester, initialTodo: initial);

    expect(find.text('할 일 편집'), findsOneWidget);
    expect(find.widgetWithText(TextField, '예전 제목'), findsOneWidget);
    // "저장" 버튼 (add 모드의 "추가" 가 아닌).
    expect(find.widgetWithText(FilledButton, '저장'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '추가'), findsNothing);
  });

  testWidgets('edit 모드 — description 가 있으면 default 펼침', (tester) async {
    final initial = makeInitial(description: '기존 메모입니다.');
    await mount(tester, initialTodo: initial);

    // TextField (제목 + description) 2개 노출.
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('기존 메모입니다.'), findsOneWidget);
  });

  testWidgets('edit 모드 — 저장 → onUpdate 호출 + onSubmit 안 호출', (tester) async {
    final initial = makeInitial(title: '예전 제목');
    final result = await mount(tester, initialTodo: initial);

    await tester.enterText(find.widgetWithText(TextField, '예전 제목'), '새 제목');
    await tester.pumpAndSettle();

    // viewport 밖에 있을 수도 있어 직접 onPressed 호출.
    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(result.submissions, isEmpty, reason: 'edit 모드에서는 onSubmit 호출 안 됨');
    expect(result.updates, hasLength(1));
    expect(result.updates.single.id, 'edit-1');
    expect(result.updates.single.title, '새 제목');
  });

  testWidgets('edit 모드 — description 변경 후 저장 → onUpdate.description 갱신', (
    tester,
  ) async {
    final initial = makeInitial(description: '옛 메모');
    final result = await mount(tester, initialTodo: initial);

    // description TextField 는 두 번째 TextField. enterText 로 새 값 입력.
    final descField = find.widgetWithText(TextField, '옛 메모');
    expect(descField, findsOneWidget);
    await tester.enterText(descField, '새 메모 내용\n여러 줄 가능');
    await tester.pumpAndSettle();

    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(result.updates, hasLength(1));
    expect(result.updates.single.description, '새 메모 내용\n여러 줄 가능');
  });

  testWidgets('edit 모드 — 기간 todo prefill → 기간 row 노출 + 저장 시 endAt 보존', (
    tester,
  ) async {
    final initial = makeInitial().copyWith(
      dueAt: DateTime(2026, 5, 27),
      endAt: DateTime(2026, 5, 30),
      isAllDay: true,
    );
    final result = await mount(tester, initialTodo: initial);

    expect(find.byKey(const ValueKey('range-start-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('range-end-row')), findsOneWidget);

    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(result.updates, hasLength(1));
    expect(result.updates.single.dueAt, DateTime(2026, 5, 27));
    expect(result.updates.single.endAt, DateTime(2026, 5, 30));
    expect(result.updates.single.isAllDay, isTrue);
  });

  testWidgets('edit 모드 — 마감시간 todo prefill → timeAnchor end 보존', (
    tester,
  ) async {
    final initial = makeInitial().copyWith(
      dueAt: DateTime(2026, 5, 27, 18, 0),
      timeAnchor: 'end',
    );
    final result = await mount(tester, initialTodo: initial);

    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(result.updates.single.timeAnchor, 'end');
    expect(result.updates.single.dueAt, DateTime(2026, 5, 27, 18, 0));
    expect(result.updates.single.endAt, isNull);
  });

  // 열람 목적으로 탭해서 시트를 열었다가 그냥 저장을 눌렀을 때, 시트가 만들어내는
  // Todo 가 원본과 완전히 동일해야 한다. 한 필드라도 재구성 편차가 생기면 컨트롤러의
  // "변경 없음 → 자리 유지" 판정이 무너져 항목이 맨 위로 튄다.
  group('열람 후 그냥 저장 — 원본과 동일한 Todo 가 넘어온다', () {
    Future<void> expectRoundTrip(WidgetTester tester, Todo initial) async {
      final result = await mount(tester, initialTodo: initial);

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '저장'),
      );
      saveBtn.onPressed?.call();
      await tester.pumpAndSettle();

      expect(result.updates.single, initial);
    }

    testWidgets('날짜 없음', (tester) async {
      await expectRoundTrip(tester, makeInitial(description: '메모 한 줄'));
    });

    testWidgets('하루종일', (tester) async {
      await expectRoundTrip(
        tester,
        makeInitial().copyWith(dueAt: DateTime(2026, 5, 27), isAllDay: true),
      );
    });

    testWidgets('시작시간', (tester) async {
      await expectRoundTrip(
        tester,
        makeInitial().copyWith(dueAt: DateTime(2026, 5, 27, 9, 30)),
      );
    });

    testWidgets('마감시간', (tester) async {
      await expectRoundTrip(
        tester,
        makeInitial().copyWith(
          dueAt: DateTime(2026, 5, 27, 18),
          timeAnchor: 'end',
        ),
      );
    });

    testWidgets('기간', (tester) async {
      await expectRoundTrip(
        tester,
        makeInitial().copyWith(
          dueAt: DateTime(2026, 5, 27),
          endAt: DateTime(2026, 5, 30),
          isAllDay: true,
        ),
      );
    });
  });

  testWidgets('edit 모드 — 제목 비우면 저장 비활성', (tester) async {
    final initial = makeInitial(title: '제목');
    await mount(tester, initialTodo: initial);

    await tester.enterText(find.widgetWithText(TextField, '제목'), '');
    await tester.pumpAndSettle();

    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    expect(saveBtn.onPressed, isNull);
  });

  testWidgets('§14-C — task(done+dueAt+calendar)→note 전환 시 정합 정리', (
    tester,
  ) async {
    final initial = Todo(
      id: 'edit-1',
      title: '완료된 일',
      category: Category.work,
      dueAt: DateTime.utc(2026, 5, 28, 9),
      doneAt: DateTime.utc(2026, 5, 28, 10),
      createdAt: DateTime.utc(2026, 5, 28),
      updatedAt: DateTime.utc(2026, 5, 28),
      calendarEventId: 'evt-123',
      type: TodoType.task,
    );
    final result = await mount(tester, initialTodo: initial);

    await tester.ensureVisible(find.byKey(const ValueKey('type-note')));
    await tester.tap(find.byKey(const ValueKey('type-note')));
    await tester.pumpAndSettle();

    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    final u = result.updates.single;
    expect(u.type, TodoType.note);
    expect(u.doneAt, isNull, reason: 'note 는 체크 개념 없음 → doneAt 제거');
    expect(u.calendarEventId, isNull, reason: 'note 는 일정 없음 → calendar 링크 제거');
    expect(u.dueAt, isNull, reason: 'note 는 일정 무관 → dueAt 제거');
  });

  testWidgets('§14-C — note→task 전환 시 type=task', (tester) async {
    final initial = makeInitial(title: '메모', type: TodoType.note);
    final result = await mount(tester, initialTodo: initial);

    await tester.ensureVisible(find.byKey(const ValueKey('type-task')));
    await tester.tap(find.byKey(const ValueKey('type-task')));
    await tester.pumpAndSettle();

    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(result.updates.single.type, TodoType.task);
  });
}
