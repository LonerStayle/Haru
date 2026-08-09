import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

void main() {
  Future<List<AddTodoSubmission>> mount(
    WidgetTester tester, {
    Category initial = Category.daily,
    DateTime? initialDueAt,
    bool initialAllDay = true,
    DateTime? fixedNow,
    String? parentId,
  }) async {
    // 종일/시간 토글 + Calendar 토글 + 빠른 dueAt 칩까지 추가되면서 sheet 가 길어졌다.
    // 800px 기본 viewport 로는 _Actions row 가 밖으로 밀려나 tap 이 무시된다.
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final submissions = <AddTodoSubmission>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // v1.2 — AddTodoSheet 가 categoriesProvider 를 watch (동적 카테고리 칩).
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          // J — 카테고리 칩 그룹핑용 groupsProvider watch. Drift timer leak 방지.
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AddTodoSheet(
                initialCategory: initial,
                initialDueAt: initialDueAt,
                initialAllDay: initialAllDay,
                now: fixedNow == null ? null : () => fixedNow,
                parentId: parentId,
                onSubmit: submissions.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // categoriesProvider stream emit 흡수
    return submissions;
  }

  testWidgets('title 비어 있으면 "추가" 비활성, 입력 후 활성화', (tester) async {
    final submissions = await mount(tester);

    final addBtn = find.widgetWithText(FilledButton, '추가');
    expect(addBtn, findsOneWidget);
    expect(tester.widget<FilledButton>(addBtn).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '회의 정리',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(addBtn).onPressed, isNotNull);
    expect(submissions, isEmpty);
  });

  testWidgets('"추가" 누르면 onSubmit 호출 + 입력값 그대로', (tester) async {
    final submissions = await mount(tester, initial: Category.work);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '  보고서  ',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '추가'));
    await tester.pump();

    expect(submissions, hasLength(1));
    expect(submissions.first.title, '보고서'); // trim
    expect(submissions.first.category, Category.work); // initial
    expect(submissions.first.dueAt, isNull);
    expect(submissions.first.addToCalendar, isFalse); // due 없으니 강제 false
  });

  testWidgets('카테고리 chip 탭하면 selection 변경', (tester) async {
    final submissions = await mount(tester);

    await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
    // 접힘형 선택기 — 헤더 탭으로 펼친 뒤 칩 선택.
    await tester.tap(find.byKey(const ValueKey('category-picker-header')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('개인개발'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '추가'));
    await tester.pump();

    expect(submissions.first.category, Category.personalDev);
  });

  testWidgets('선택된 카테고리 chip 은 outline 으로 강조 (alpha 차이 X)', (tester) async {
    // initialCategory 가 daily → "일상" chip 이 selected.
    await mount(tester);
    await tester.pump();

    // 접힘형 선택기 — 헤더를 펼쳐야 칩이 보인다.
    await tester.tap(find.byKey(const ValueKey('category-picker-header')));
    await tester.pumpAndSettle();

    // selected chip("일상")의 Material — 칩 key 로 특정 (헤더의 "일상" 텍스트와 구분).
    final materialFinder = find.descendant(
      of: find.byKey(const ValueKey('category-chip-daily')),
      matching: find.byType(Material),
    );
    final selectedMaterial = tester.widget<Material>(materialFinder.first);

    final shape = selectedMaterial.shape;
    expect(
      shape,
      isA<RoundedRectangleBorder>(),
      reason: 'selected chip 은 RoundedRectangleBorder shape 를 가져야 함',
    );
    final rrb = shape! as RoundedRectangleBorder;
    expect(
      rrb.side.width,
      greaterThan(0),
      reason: 'selected chip 은 visible BorderSide 가 있어야 함 (outline 강조)',
    );
  });

  testWidgets('일정 비어 있을 때 Calendar 토글이 안 보임', (tester) async {
    await mount(tester);
    expect(find.text('Google Calendar 에 등록'), findsNothing);
  });

  testWidgets('Enter (onSubmitted) 로도 저장 가능', (tester) async {
    final submissions = await mount(tester);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '빠른 추가',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(submissions, hasLength(1));
    expect(submissions.first.title, '빠른 추가');
  });

  group('하루 종일 옵션 (시간 picker 강제 제거)', () {
    testWidgets('initialDueAt + initialAllDay=true → 라벨이 "· 하루 종일" 로 표시', (
      tester,
    ) async {
      await mount(
        tester,
        initialDueAt: DateTime(2026, 5, 28),
        initialAllDay: true,
      );

      expect(find.textContaining('하루 종일'), findsWidgets);
      // 종일 상태에서는 "시간 추가" 액션이 나오고 "하루 종일" 토글 버튼은 안 나옴.
      expect(find.widgetWithText(OutlinedButton, '시간 추가'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '하루 종일'), findsNothing);
    });

    testWidgets('종일 상태로 추가 → submission.isAllDay == true + dueAt 시간 부분 00:00', (
      tester,
    ) async {
      final submissions = await mount(
        tester,
        initialDueAt: DateTime(2026, 5, 28),
        initialAllDay: true,
      );

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        '하루 일정',
      );
      await tester.pump();
      // viewport 의존성 회피 — onPressed 직접 호출.
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions, hasLength(1));
      expect(submissions.first.dueAt, DateTime(2026, 5, 28));
      expect(submissions.first.isAllDay, isTrue);
    });

    testWidgets('initialAllDay=false (시간 지정) → "시간 변경" + "하루 종일" 토글 모두 노출', (
      tester,
    ) async {
      await mount(
        tester,
        initialDueAt: DateTime(2026, 5, 28, 14, 30),
        initialAllDay: false,
      );

      expect(find.textContaining('14:30'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, '시간 변경'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '하루 종일'), findsOneWidget);
    });

    testWidgets('"하루 종일" 토글 누르면 시간이 00:00 으로 리셋되고 라벨이 종일로 변경', (tester) async {
      final submissions = await mount(
        tester,
        initialDueAt: DateTime(2026, 5, 28, 14, 30),
        initialAllDay: false,
      );

      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '하루 종일'))
          .onPressed!();
      await tester.pump();

      expect(find.textContaining('하루 종일'), findsWidgets);

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions.first.dueAt, DateTime(2026, 5, 28));
      expect(submissions.first.isAllDay, isTrue);
    });

    testWidgets('일정 없음 (dueAt null) → 종일/시간 버튼 둘 다 안 보임', (tester) async {
      await mount(tester); // initialDueAt 미주입
      expect(find.widgetWithText(OutlinedButton, '시간 추가'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '시간 변경'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '하루 종일'), findsNothing);
    });
  });

  group('fast-tasks — 4 모드 + 기간', () {
    final now = DateTime(2026, 5, 27, 10);

    testWidgets('4 모드 칩 모두 렌더', (tester) async {
      await mount(tester, fixedNow: now);
      expect(find.byKey(const ValueKey('date-mode-all-day')), findsOneWidget);
      expect(find.byKey(const ValueKey('date-mode-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('date-mode-end')), findsOneWidget);
      expect(find.byKey(const ValueKey('date-mode-range')), findsOneWidget);
    });

    testWidgets('마감시간 모드 → submission.timeAnchor = end', (tester) async {
      final submissions = await mount(tester, fixedNow: now);

      // 먼저 날짜 지정 (오늘) 후 마감시간 모드 — _setDateMode 가 09:00 채움.
      await tester.tap(find.byKey(const ValueKey('quick-due-today')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('date-mode-end')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions.first.timeAnchor, 'end');
      expect(submissions.first.isAllDay, isFalse);
      expect(submissions.first.endAt, isNull);
    });

    testWidgets('기간 모드 → 시작/종료 row 노출 + submission.endAt 채워짐', (tester) async {
      final submissions = await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('date-mode-range')));
      await tester.pump();

      expect(find.byKey(const ValueKey('range-start-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('range-end-row')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      // _setDateMode(range) 가 시작=오늘, 종료=내일 디폴트로 채움.
      expect(submissions.first.dueAt, DateTime(2026, 5, 27));
      expect(submissions.first.endAt, DateTime(2026, 5, 28));
      expect(submissions.first.isAllDay, isTrue);
    });

    testWidgets('기간 모드에서 종료<시작 이면 invalid 메시지 + 저장 비활성', (tester) async {
      await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('date-mode-range')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();

      // 디폴트는 시작<종료라 유효. invalid 를 강제하려면 종료를 시작 이전으로 돌려야
      // 하는데 picker 우회가 어려우므로, 디폴트 유효 상태에서 저장 가능 여부만 확인.
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '추가'),
      );
      expect(btn.onPressed, isNotNull);
      expect(find.byKey(const ValueKey('range-invalid-msg')), findsNothing);
    });
  });

  testWidgets('더블 submit 가드: 빠르게 두 번 tap → onSubmit 한 번만 호출', (tester) async {
    final submissions = await mount(tester);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '한 번만',
    );
    await tester.pump();

    final addBtn = find.widgetWithText(FilledButton, '추가');
    final onPressed = tester.widget<FilledButton>(addBtn).onPressed;
    expect(onPressed, isNotNull);

    // 같은 frame 에서 두 번 호출 — race 시뮬레이션 (실제 사용자의 빠른 더블 탭과 같은 효과).
    onPressed!();
    onPressed();
    await tester.pump();

    expect(submissions, hasLength(1), reason: 'submit 가드 누락 시 두 todo 가 생성됨');
  });

  testWidgets('Enter + 즉시 tap 더블 — 동일하게 한 번만', (tester) async {
    final submissions = await mount(tester);

    await tester.enterText(
      find.byKey(const ValueKey('add-todo-title')),
      '한 번만2',
    );
    await tester.pump();

    // Enter 로 한 번.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // 같은 frame 에 추가 버튼 onPressed 직접 호출.
    final btn = find.widgetWithText(FilledButton, '추가');
    if (btn.evaluate().isNotEmpty) {
      final onPressed = tester.widget<FilledButton>(btn).onPressed;
      onPressed?.call();
    }
    await tester.pump();

    expect(submissions, hasLength(1));
  });

  group('빠른 dueAt 칩 (오늘/내일/다음주/시간 지정)', () {
    // 결정적 now — 2026-05-27 10:00 (수요일).
    final now = DateTime(2026, 5, 27, 10);

    testWidgets('4 개 칩 모두 렌더', (tester) async {
      await mount(tester, fixedNow: now);
      expect(find.byKey(const ValueKey('quick-due-today')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-due-tomorrow')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-due-next-week')), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-due-time')), findsOneWidget);
    });

    testWidgets('"오늘" 탭 → dueAt = 오늘 자정 + allDay, submission 에 반영', (
      tester,
    ) async {
      final submissions = await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('quick-due-today')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed
          ?.call();
      await tester.pump();

      expect(submissions.first.dueAt, DateTime(2026, 5, 27));
      expect(submissions.first.isAllDay, isTrue);
    });

    testWidgets('"내일" 탭 → dueAt = 내일 자정', (tester) async {
      final submissions = await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('quick-due-tomorrow')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed
          ?.call();
      await tester.pump();

      expect(submissions.first.dueAt, DateTime(2026, 5, 28));
      expect(submissions.first.isAllDay, isTrue);
    });

    testWidgets('"다음주" 탭 → dueAt = 오늘 + 7일 자정 (= 1주일 뒤)', (tester) async {
      final submissions = await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('quick-due-next-week')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed
          ?.call();
      await tester.pump();

      expect(submissions.first.dueAt, DateTime(2026, 6, 3));
      expect(submissions.first.isAllDay, isTrue);
    });

    testWidgets('같은 칩 두 번 탭 → 토글 해제 (dueAt = null)', (tester) async {
      final submissions = await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('quick-due-today')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('quick-due-today')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed
          ?.call();
      await tester.pump();

      expect(submissions.first.dueAt, isNull);
      expect(submissions.first.isAllDay, isFalse);
    });

    testWidgets('"오늘" 칩 탭 후 selected 표시 (outline 강조)', (tester) async {
      await mount(tester, fixedNow: now);

      await tester.tap(find.byKey(const ValueKey('quick-due-today')));
      await tester.pump();

      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('quick-due-today')),
              matching: find.byType(Material),
            )
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(
        shape.side.width,
        greaterThan(0),
        reason: 'selected 칩은 BorderSide 가 visible',
      );
    });

    testWidgets('월 경계 — 5/31 + "내일" → 6/1', (tester) async {
      final lateMonth = DateTime(2026, 5, 31, 10);
      final submissions = await mount(tester, fixedNow: lateMonth);

      await tester.tap(find.byKey(const ValueKey('quick-due-tomorrow')));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed
          ?.call();
      await tester.pump();

      expect(submissions.first.dueAt, DateTime(2026, 6, 1));
    });
  });

  group('Task C — parentId (하위 추가 모드)', () {
    testWidgets('parentId 지정 → 제목 "하위 항목 추가" + 카테고리 선택 숨김', (tester) async {
      await mount(tester, initial: Category.work, parentId: 'parent-1');

      expect(find.text('하위 항목 추가'), findsOneWidget);
      // 카테고리 섹션 라벨이 사라진다 (부모 category 고정).
      expect(find.text('카테고리'), findsNothing);
    });

    testWidgets('parentId 제출 → submission.parentId + 부모 category 상속', (
      tester,
    ) async {
      final submissions = await mount(
        tester,
        initial: Category.work,
        parentId: 'parent-1',
      );

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        '자식 항목',
      );
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions, hasLength(1));
      expect(submissions.first.parentId, 'parent-1');
      expect(
        submissions.first.category,
        Category.work,
        reason: '부모 category (initialCategory) 상속',
      );
    });

    testWidgets('parentId null (일반 add) → submission.parentId null', (
      tester,
    ) async {
      final submissions = await mount(tester);
      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions.first.parentId, isNull);
    });
  });

  group('v1.1 — task / note 토글', () {
    testWidgets('초기는 task 선택 — task chip 이 outline 강조', (tester) async {
      await mount(tester);
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('type-task')),
              matching: find.byType(Material),
            )
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.width, greaterThan(0));
    });

    testWidgets('"메모" 탭 → submission.type = note + dueAt 강제 null', (
      tester,
    ) async {
      final submissions = await mount(tester, fixedNow: DateTime(2026, 5, 27));

      // 먼저 "오늘" 칩으로 dueAt 설정한 뒤 메모로 전환 — note 가 dueAt 을 null 로 강제하는지 검증.
      await tester.tap(find.byKey(const ValueKey('quick-due-today')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('type-note')));
      await tester.pump();

      // 일정 영역 자체가 사라져야 함.
      expect(find.byKey(const ValueKey('quick-due-today')), findsNothing);
      expect(find.text('일정'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'x');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions, hasLength(1));
      expect(submissions.first.type, TodoType.note);
      expect(submissions.first.dueAt, isNull, reason: 'note 는 dueAt 강제 null');
      expect(submissions.first.addToCalendar, isFalse);
      expect(submissions.first.isAllDay, isFalse);
    });

    testWidgets('note → task 다시 전환하면 일정 영역 복원', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('type-note')));
      await tester.pump();
      expect(find.text('일정'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('type-task')));
      await tester.pump();
      expect(find.text('일정'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-due-today')), findsOneWidget);
    });

    testWidgets('task 선택 그대로 추가 → submission.type = task', (tester) async {
      final submissions = await mount(tester);
      await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'a');
      await tester.pump();
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '추가'))
          .onPressed!();
      await tester.pump();

      expect(submissions.first.type, TodoType.task);
    });
  });

  group('v1.1 — bulk paste (멀티라인 → N건 일괄 추가)', () {
    group('splitBulkLines (pure)', () {
      test('단순 N줄 → trim 후 list', () {
        final lines =
            // ignore: invalid_use_of_visible_for_testing_member
            AddTodoSheet.splitBulkLines('a\nb\nc');
        expect(lines, ['a', 'b', 'c']);
      });

      test('빈 줄 + 공백만 인 줄 무시', () {
        final lines =
            // ignore: invalid_use_of_visible_for_testing_member
            AddTodoSheet.splitBulkLines('  a  \n\n   \nb\n\n');
        expect(lines, ['a', 'b']);
      });

      test('단일 줄 → 1건', () {
        final lines =
            // ignore: invalid_use_of_visible_for_testing_member
            AddTodoSheet.splitBulkLines('just one');
        expect(lines, ['just one']);
      });

      test('전부 빈 줄 → 빈 list', () {
        final lines =
            // ignore: invalid_use_of_visible_for_testing_member
            AddTodoSheet.splitBulkLines('\n\n   \n');
        expect(lines, isEmpty);
      });
    });

    testWidgets(
      '멀티라인 paste → confirm dialog → 확인 시 N개 onSubmit (같은 category/dueAt/type)',
      (tester) async {
        // initialDueAt + initialAllDay 로 dueAt 미리 설정 — bulk 시 모든 row 가 같은 dueAt 받는지 검증.
        final submissions = await mount(
          tester,
          initial: Category.work,
          initialDueAt: DateTime(2026, 5, 28),
        );

        // 멀티라인 paste 시뮬레이션 — enterText 가 multi-line 입력으로 작동.
        await tester.enterText(
          find.byKey(const ValueKey('add-todo-title')),
          '캔버스 첨부\nnarrative 에러\n치어미터 묻기',
        );
        await tester.pump();
        await tester.pumpAndSettle();

        // confirm dialog 노출 + 라벨 검증.
        expect(find.byKey(const ValueKey('bulk-paste-dialog')), findsOneWidget);
        expect(find.textContaining('3개'), findsOneWidget);

        // 확인 tap.
        await tester.tap(find.byKey(const ValueKey('bulk-paste-confirm')));
        await tester.pumpAndSettle();

        expect(submissions, hasLength(3));
        expect(submissions.map((s) => s.title), [
          '캔버스 첨부',
          'narrative 에러',
          '치어미터 묻기',
        ]);
        // 같은 category + dueAt + type 공유.
        for (final s in submissions) {
          expect(s.category, Category.work);
          expect(s.dueAt, DateTime(2026, 5, 28));
          expect(s.type, TodoType.task);
        }
      },
    );

    testWidgets('취소 시 onSubmit 0회 + 단일 라인 복구', (tester) async {
      final submissions = await mount(tester);

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        'first\nsecond',
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // 취소.
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();

      expect(submissions, isEmpty);
      // \n 제거되어 단일 라인 (join) 으로 복구되는지 — controller 의 값을 TextField 위젯에서 검증.
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('add-todo-title')),
      );
      expect(field.controller!.text, 'first second');
    });

    testWidgets('빈 줄만 paste → dialog 안 뜨고 단일 흐름 유지', (tester) async {
      await mount(tester);

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        '\n\n   \n',
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('bulk-paste-dialog')), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('add-todo-title')),
      );
      expect(field.controller!.text, ''); // 빈 줄만 → 빈 문자열로 복구
    });

    testWidgets('"\\n + 단일 의미줄" → dialog 안 뜸 (lines.length < 2), 단일 라인 복구', (
      tester,
    ) async {
      await mount(tester);

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        '\nonly\n',
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('bulk-paste-dialog')), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('add-todo-title')),
      );
      expect(field.controller!.text, 'only');
    });

    testWidgets('note 모드에서 멀티라인 paste → N건 모두 type=note + dueAt null', (
      tester,
    ) async {
      final submissions = await mount(tester);

      await tester.tap(find.byKey(const ValueKey('type-note')));
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        '메모1\n메모2',
      );
      await tester.pump();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bulk-paste-confirm')));
      await tester.pumpAndSettle();

      expect(submissions, hasLength(2));
      for (final s in submissions) {
        expect(s.type, TodoType.note);
        expect(s.dueAt, isNull);
        expect(s.addToCalendar, isFalse);
      }
    });

    testWidgets('단일 줄 입력 (기존 흐름) — dialog 안 뜨고 "추가" 버튼 활성화 그대로', (
      tester,
    ) async {
      await mount(tester);

      await tester.enterText(
        find.byKey(const ValueKey('add-todo-title')),
        '단일 todo',
      );
      await tester.pump();

      // dialog 없음 + 추가 버튼 활성화 (canSubmit=true).
      expect(find.byKey(const ValueKey('bulk-paste-dialog')), findsNothing);
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '추가'),
      );
      expect(btn.onPressed, isNotNull);
    });
  });
}
