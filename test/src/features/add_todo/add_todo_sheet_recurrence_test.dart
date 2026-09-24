import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

import '../../../helpers/add_todo_sheet_helpers.dart';

void main() {
  final submissions = <AddTodoSubmission>[];

  setUp(submissions.clear);

  // AddTodoSheet 가 watch 하는 stream provider 를 Stream.value 로 override —
  // 실제 Drift 의존 + timer leak 회피 (기존 add_todo_sheet_test 와 동일 패턴).
  Future<void> mount(WidgetTester tester, {DateTime? initialDueAt}) async {
    // 반복 섹션까지 추가돼 시트가 길어졌다 — tall viewport 로 모든 칩이 hit-test
    // 영역에 들어오게 한다(off-screen tap miss 방지).
    await tester.binding.setSurfaceSize(const Size(420, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
            body: SingleChildScrollView(
              child: AddTodoSheet(
                onSubmit: submissions.add,
                initialCategory: Category.work,
                initialDueAt: initialDueAt,
                now: () => DateTime(2026, 1, 5, 9), // 월요일
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // categoriesProvider stream emit 흡수
    await openSheetMore(tester);
  }

  Future<void> enterTitle(WidgetTester tester, String text) =>
      tester.enterText(find.byKey(const ValueKey('add-todo-title')), text);

  testWidgets('날짜 없으면 반복 섹션 숨김', (tester) async {
    await mount(tester);
    expect(find.text('반복'), findsNothing);
    expect(find.byKey(const ValueKey('recur-freq-none')), findsNothing);
  });

  testWidgets('날짜 있으면 반복 섹션 노출, 기본 "안 함"', (tester) async {
    await mount(tester, initialDueAt: DateTime(2026, 1, 5));
    expect(find.text('반복'), findsOneWidget);
    expect(find.byKey(const ValueKey('recur-freq-none')), findsOneWidget);
    // 안 함 상태 — interval/요일 미노출.
    expect(find.byKey(const ValueKey('recur-interval-label')), findsNothing);
  });

  testWidgets('매일 선택 + 제목 입력 → submission.recurrence = daily', (tester) async {
    await mount(tester, initialDueAt: DateTime(2026, 1, 5));
    await enterTitle(tester, '비타민');
    await tester.tap(find.byKey(const ValueKey('recur-freq-daily')));
    await tester.pump();
    expect(find.byKey(const ValueKey('recur-interval-label')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '추가'));
    await tester.pump();

    expect(submissions, hasLength(1));
    expect(
      submissions.single.recurrence,
      const RecurrenceRule(freq: RecurrenceFreq.daily),
    );
  });

  testWidgets('간격 스텝퍼 +1 → interval 2', (tester) async {
    await mount(tester, initialDueAt: DateTime(2026, 1, 5));
    await enterTitle(tester, '격주 회의');
    await tester.tap(find.byKey(const ValueKey('recur-freq-weekly')));
    await tester.pumpAndSettle(); // 더보기 영역이 커지는 애니메이션까지.
    await tester.tap(find.byKey(const ValueKey('recur-interval-plus')));
    await tester.pump();
    expect(find.text('2주마다'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '추가'));
    await tester.pump();

    final r = submissions.single.recurrence!;
    expect(r.freq, RecurrenceFreq.weekly);
    expect(r.interval, 2);
    // 매주 선택 시 dueAt(월요일=1) 요일이 기본으로 켜진다.
    expect(r.byWeekday, contains(DateTime.monday));
  });

  testWidgets('매주 요일 토글 — 수요일 추가', (tester) async {
    await mount(tester, initialDueAt: DateTime(2026, 1, 5));
    await enterTitle(tester, '주간보고');
    await tester.tap(find.byKey(const ValueKey('recur-freq-weekly')));
    await tester.pumpAndSettle(); // 더보기 영역이 커지는 애니메이션까지.
    await tester.tap(find.byKey(const ValueKey('recur-weekday-3'))); // 수
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '추가'));
    await tester.pump();

    final r = submissions.single.recurrence!;
    expect(r.byWeekday, containsAll([DateTime.monday, DateTime.wednesday]));
  });

  testWidgets('안 함이면 submission.recurrence = null', (tester) async {
    await mount(tester, initialDueAt: DateTime(2026, 1, 5));
    await enterTitle(tester, '단발 할일');
    await tester.pump(); // 제목 입력 반영 → submit 버튼 활성화(canSubmit rebuild)
    await tester.tap(find.widgetWithText(FilledButton, '추가'));
    await tester.pump();
    expect(submissions.single.recurrence, isNull);
  });
}
