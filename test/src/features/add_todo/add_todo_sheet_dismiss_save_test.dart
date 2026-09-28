import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// 편집 자동 저장 — edit 모드 시트를 배경 탭 등으로 그냥 닫아도 입력값이 저장된다.
///
/// 신규 추가 모드는 기존대로 닫힘 = 취소 (추가 버튼을 눌러야만 생성). 저장 버튼
/// 경로와 닫힘 훅이 중복 호출되지 않는지도 함께 검증한다.
void main() {
  Future<({List<AddTodoSubmission> submissions, List<Todo> updates})> mountApp(
    WidgetTester tester, {
    Todo? initialTodo,
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
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const ValueKey('open-sheet'),
                  onPressed: () => AddTodoSheet.show(
                    context,
                    initialCategory: Category.daily,
                    initialTodo: initialTodo,
                    onSubmit: submissions.add,
                    onUpdate: updates.add,
                  ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();
    return (submissions: submissions, updates: updates);
  }

  Todo makeInitial({String title = '예전 제목', TodoType type = TodoType.task}) =>
      Todo(
        id: 'edit-1',
        title: title,
        category: Category.work,
        dueAt: null,
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 28),
        updatedAt: DateTime.utc(2026, 5, 28),
        calendarEventId: null,
        type: type,
      );

  // 시트 밖 (화면 최상단) 탭 = modal barrier 탭 → 시트 닫힘.
  Future<void> tapBarrier(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  testWidgets('edit 모드 — 제목 고치고 배경 탭 → onUpdate 자동 호출', (tester) async {
    final result = await mountApp(tester, initialTodo: makeInitial());

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '새 제목',
    );
    await tester.pump();
    await tapBarrier(tester);

    expect(find.byType(AddTodoSheet), findsNothing, reason: '시트는 닫혀야 함');
    expect(result.updates, hasLength(1));
    expect(result.updates.single.title, '새 제목');
    expect(result.submissions, isEmpty);
  });

  testWidgets('edit 모드 — note(메모)도 배경 탭으로 수정 반영', (tester) async {
    final result = await mountApp(
      tester,
      initialTodo: makeInitial(title: '옛 메모', type: TodoType.note),
    );

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '고친 메모',
    );
    await tester.pump();
    await tapBarrier(tester);

    expect(result.updates, hasLength(1));
    expect(result.updates.single.title, '고친 메모');
    expect(result.updates.single.type, TodoType.note);
  });

  testWidgets('edit 모드 — 무변경 배경 탭도 onUpdate 호출 (no-op 판정은 컨트롤러 몫)', (
    tester,
  ) async {
    final initial = makeInitial();
    final result = await mountApp(tester, initialTodo: initial);

    await tapBarrier(tester);

    // 원본과 동일한 Todo 가 넘어와야 컨트롤러의 _isUnchanged 가 자리 유지 판정을 한다.
    expect(result.updates.single, initial);
  });

  testWidgets('edit 모드 — 저장 버튼으로 닫으면 onUpdate 1회만 (닫힘 훅 중복 X)', (tester) async {
    final result = await mountApp(tester, initialTodo: makeInitial());

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '새 제목',
    );
    await tester.pumpAndSettle();
    final saveBtn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '저장'),
    );
    saveBtn.onPressed?.call();
    await tester.pumpAndSettle();

    expect(result.updates, hasLength(1));
    expect(result.updates.single.title, '새 제목');
  });

  testWidgets('edit 모드 — 제목 비우고 배경 탭 → 저장 안 함 (취소)', (tester) async {
    final result = await mountApp(tester, initialTodo: makeInitial());

    await tester.enterText(find.byKey(const ValueKey('add-todo-title')), '');
    await tester.pump();
    await tapBarrier(tester);

    expect(result.updates, isEmpty, reason: '빈 제목은 저장 불가 → 닫힘 = 취소');
  });

  testWidgets('add 모드 — 배경 탭 닫힘은 기존대로 취소 (onSubmit 호출 X)', (tester) async {
    final result = await mountApp(tester);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '입력만 하고 닫기',
    );
    await tester.pump();
    await tapBarrier(tester);

    expect(result.submissions, isEmpty, reason: '신규 생성은 추가 버튼을 눌러야만 적용');
    expect(result.updates, isEmpty);
  });
}
