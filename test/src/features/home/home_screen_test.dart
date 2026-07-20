import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/home_screen.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

void main() {
  /// HomeScreen 을 [stream] (controlled-async) 으로 띄운다. 실제 Drift 의존성 없이
  /// UI 만 결정성 있게 검증.
  Future<StreamController<List<Todo>>> mountWith(
    WidgetTester tester, {
    required DateTime fixedNow,
    ThemeData? theme,
    Stream<int>? outboxCountStream,
    List<Todo> allTodos = const [],
  }) async {
    final controller = StreamController<List<Todo>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => fixedNow),
          watchTodayTodosProvider.overrideWith((_) => controller.stream),
          // date-repeat — materializer 는 실제 repo 를 watch 하므로 테스트에선 no-op.
          recurrenceMaterializerProvider.overrideWith((_) {}),
          outboxCountProvider.overrideWith(
            (_) => outboxCountStream ?? Stream<int>.value(0),
          ),
          // v1.1 — breadcrumb 용 allTodosProvider. Drift 의존 + timer leak 회피.
          allTodosProvider.overrideWith((_) => Stream.value(allTodos)),
          // 오늘 화면 카테고리 섹션 헤더의 그룹 라벨용. Drift 의존 + timer leak 회피.
          groupsProvider.overrideWith((_) => Stream.value(const [])),
          // 보관 필터(visibleTodayTodosProvider)가 categoriesProvider 를 참조 — Drift 회피.
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
        ],
        child: MaterialApp(
          theme: theme ?? AppTheme.mobileLight(),
          home: const Scaffold(body: HomeScreen()),
        ),
      ),
    );
    return controller;
  }

  Todo todo({
    required String id,
    String title = 'x',
    Category category = Category.daily,
    DateTime? dueAt,
    DateTime? doneAt,
    DateTime? createdAt,
  }) {
    final c = createdAt ?? DateTime.utc(2026, 5, 27, 1);
    return Todo(
      id: id,
      title: title,
      category: category,
      dueAt: dueAt,
      doneAt: doneAt,
      createdAt: c,
      updatedAt: c,
      calendarEventId: null,
    );
  }

  testWidgets('빈 list → 빈 상태 ("오늘 할 일이 없어요") + 이월 배너 없음', (tester) async {
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
    );
    controller.add(<Todo>[]);
    await tester.pump();

    expect(find.text('오늘 할 일이 없어요'), findsOneWidget);
    expect(find.textContaining('이월'), findsNothing);
  });

  testWidgets('오늘 todo 1건 — title + 시간 노출, 이월 배너 없음', (tester) async {
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
    );
    controller.add([
      todo(
        id: 'a',
        title: 'PR 리뷰',
        category: Category.personalDev,
        dueAt: DateTime(2026, 5, 27, 14, 30),
      ),
    ]);
    await tester.pump();

    expect(find.text('PR 리뷰'), findsOneWidget);
    // fast-tasks — 시간 모드는 "시작 M/D HH:mm" 라벨로 표시 (시각 포함).
    expect(find.textContaining('14:30'), findsOneWidget);
    expect(find.textContaining('이월'), findsNothing);
  });

  testWidgets('어제 미체크 todo 가 있을 때 이월 배너 노출', (tester) async {
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
    );
    controller.add([
      todo(
        id: 'y',
        title: '어제 못 끝낸 일',
        category: Category.work,
        dueAt: DateTime(2026, 5, 26, 9),
        createdAt: DateTime.utc(2026, 5, 26),
      ),
    ]);
    await tester.pump();

    expect(find.text('어제 못 끝낸 일'), findsOneWidget);
    expect(find.textContaining('1건이 오늘로 이월'), findsOneWidget);
  });

  testWidgets('이월 배너 — light 테마에서 bg alpha 0.08', (tester) async {
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
      theme: AppTheme.mobileLight(),
    );
    controller.add([
      todo(
        id: 'y',
        category: Category.work,
        dueAt: DateTime(2026, 5, 26, 9),
        createdAt: DateTime.utc(2026, 5, 26),
      ),
    ]);
    await tester.pump();

    final banner = tester.widget<Container>(
      find.byKey(const ValueKey('carryover-banner')),
    );
    final bgAlpha = (banner.decoration! as BoxDecoration).color!.a;
    expect(bgAlpha, closeTo(0.08, 0.005));
  });

  testWidgets('outbox count == 0 → 동기화 chip 안 보임', (tester) async {
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
    );
    controller.add(<Todo>[]);
    await tester.pump();

    expect(find.byKey(const ValueKey('sync-pending-chip')), findsNothing);
  });

  testWidgets('outbox count > 0 → "동기화 대기 N건" chip 노출', (tester) async {
    // broadcast stream — 첫 emit 이 listener 등록 후 들어오도록.
    final outboxStream = Stream<int>.value(3).asBroadcastStream();
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
      outboxCountStream: outboxStream,
    );
    controller.add(<Todo>[]);
    // stream emit + AsyncValue.data 반영을 위해 pump 두 번.
    await tester.pump();
    await tester.pump(Duration.zero);

    expect(find.byKey(const ValueKey('sync-pending-chip')), findsOneWidget);
    expect(find.textContaining('동기화 대기 3건'), findsOneWidget);
  });

  testWidgets('이월 배너 — dark 테마에서 bg alpha 가 light 보다 진함 (다크 가독성)', (
    tester,
  ) async {
    final controller = await mountWith(
      tester,
      fixedNow: DateTime(2026, 5, 27, 10),
      theme: AppTheme.mobileDark(),
    );
    controller.add([
      todo(
        id: 'y',
        category: Category.work,
        dueAt: DateTime(2026, 5, 26, 9),
        createdAt: DateTime.utc(2026, 5, 26),
      ),
    ]);
    await tester.pump();

    final banner = tester.widget<Container>(
      find.byKey(const ValueKey('carryover-banner')),
    );
    final bgAlpha = (banner.decoration! as BoxDecoration).color!.a;
    expect(
      bgAlpha,
      greaterThan(0.10),
      reason: '다크에서 light 의 0.08 보다 충분히 진해야 가독성 보장',
    );
  });

  group('기능 M — today 평면 + 드릴다운', () {
    testWidgets('root todo 1건 (자식 없음) → 그대로 표시, 드릴 배지 없음', (tester) async {
      final t = todo(id: 'r', title: '회사 todo', category: Category.work);
      final controller = await mountWith(
        tester,
        fixedNow: DateTime(2026, 5, 27, 10),
        allTodos: [t],
      );
      controller.add([t]);
      await tester.pump();

      expect(find.text('회사 todo'), findsOneWidget);
      // 자식이 없으므로 드릴 배지 미표시.
      expect(find.byKey(const ValueKey('todo-tile-drill-r')), findsNothing);
    });

    testWidgets('자식 있는 root → 인라인으로 펼치지 않고 드릴 배지("하위 N") 표시', (tester) async {
      final parent = todo(id: 'p', title: 'JS슈퍼', category: Category.work);
      final child = Todo(
        id: 'c',
        title: '워크트리 만들기',
        category: Category.work,
        dueAt: null,
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 27, 1),
        updatedAt: DateTime.utc(2026, 5, 27, 1),
        calendarEventId: null,
        parentId: 'p',
      );
      final controller = await mountWith(
        tester,
        fixedNow: DateTime(2026, 5, 27, 10),
        allTodos: [parent, child],
      );
      controller.add([parent]);
      await tester.pump();

      expect(find.text('JS슈퍼'), findsOneWidget);
      // 인라인 펼침 제거 — 자식은 최상위에서 보이지 않는다 (드릴로만 접근).
      expect(
        find.text('워크트리 만들기'),
        findsNothing,
        reason: '드릴다운으로 대체 — 자식은 인라인으로 펼치지 않는다',
      );
      // 자식 있는 root 는 드릴 배지 노출.
      expect(find.byKey(const ValueKey('todo-tile-drill-p')), findsOneWidget);
      expect(find.text('하위 1'), findsOneWidget);
    });

    testWidgets(
      '오늘 task 타일에 ＋하위추가 버튼 노출 (note 자식 add-child 는 drill_list_test 에서)',
      (tester) async {
        final task = todo(id: 't', title: '할 일', category: Category.work);
        final controller = await mountWith(
          tester,
          fixedNow: DateTime(2026, 5, 27, 10),
          allTodos: [task],
        );
        controller.add([task]);
        await tester.pump();

        // §14 — 타입 무관하게 ＋하위 추가 노출. 오늘은 task 전용이라 여기선 task 만 검증.
        expect(
          find.byKey(const ValueKey('todo-tile-add-child-t')),
          findsOneWidget,
        );
      },
    );
  });
}
