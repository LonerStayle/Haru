import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

/// v1.6 — `AddTodoSheet.show()` 가 initialDueAt / initialAllDay 를 위젯까지 전달하는지.
///
/// 캘린더에서 "이 날짜로 추가" 는 날짜 입력 단계를 통째로 생략하는 것이 핵심 가치인데,
/// show() 가 이 값을 안 넘기면 그 UX 자체가 성립하지 않는다. 그래서 위젯 생성자가
/// 아니라 **show() 경로**로 검증한다.
void main() {
  Future<List<AddTodoSubmission>> openViaShow(
    WidgetTester tester, {
    DateTime? initialDueAt,
    bool initialAllDay = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final submissions = <AddTodoSubmission>[];
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
                    onSubmit: submissions.add,
                    initialDueAt: initialDueAt,
                    initialAllDay: initialAllDay,
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
    return submissions;
  }

  Future<void> submit(WidgetTester tester, String title) async {
    await tester.enterText(find.byKey(const ValueKey('add-todo-title')), title);
    await tester.pump();
    // viewport 의존성 회피 — onPressed 직접 호출 (기존 시트 테스트와 같은 관용구).
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
        .onPressed!();
    await tester.pump();
  }

  testWidgets('show(initialDueAt:) 로 연 시트는 그 날짜가 이미 채워져 있다', (tester) async {
    final submissions = await openViaShow(
      tester,
      initialDueAt: DateTime(2026, 8, 20),
    );

    expect(find.textContaining('하루 종일'), findsWidgets);

    await submit(tester, '캘린더에서 추가');

    expect(submissions, hasLength(1));
    expect(submissions.first.dueAt, DateTime(2026, 8, 20));
    expect(submissions.first.isAllDay, isTrue);
    expect(submissions.first.title, '캘린더에서 추가');
  });

  testWidgets('initialAllDay: false 면 시각 입력 모드로 열린다', (tester) async {
    final submissions = await openViaShow(
      tester,
      initialDueAt: DateTime(2026, 8, 20, 9),
      initialAllDay: false,
    );

    await submit(tester, '시각 있는 일정');

    expect(submissions.first.isAllDay, isFalse);
    expect(submissions.first.dueAt, DateTime(2026, 8, 20, 9));
  });

  testWidgets('인자를 안 주면 종전과 같이 날짜 없음 (기존 호출처 무회귀)', (tester) async {
    final submissions = await openViaShow(tester);

    await submit(tester, '날짜 없는 할 일');

    expect(submissions, hasLength(1));
    expect(submissions.first.dueAt, isNull);
  });
}
