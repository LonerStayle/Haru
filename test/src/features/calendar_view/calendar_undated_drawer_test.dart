import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_undated_drawer.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

Todo make({
  required String id,
  String title = '언젠가 할 일',
  DateTime? dueAt,
  DateTime? doneAt,
  TodoType type = TodoType.task,
  int sortOrder = 0,
}) => Todo(
  id: id,
  title: title,
  category: Category.work,
  dueAt: dueAt,
  doneAt: doneAt,
  type: type,
  sortOrder: sortOrder,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  Future<void> mount(WidgetTester tester, List<Todo> todos) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allTodosProvider.overrideWith((_) => Stream.value(todos)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [CalendarUndatedDrawer()],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  testWidgets('무날짜 항목이 없으면 서랍 자체를 숨긴다', (tester) async {
    await mount(tester, [make(id: 'dated', dueAt: DateTime(2026, 8, 15))]);
    expect(find.byKey(const ValueKey('calendar-undated-header')), findsNothing);
  });

  testWidgets('기본은 접힘 — 헤더와 건수만 보인다', (tester) async {
    await mount(tester, [make(id: 'a'), make(id: 'b')]);
    expect(
      find.byKey(const ValueKey('calendar-undated-header')),
      findsOneWidget,
    );
    expect(find.text('날짜 없음'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calendar-undated-tile-a')),
      findsNothing,
      reason: '기본 접힘이라 항목은 안 보인다',
    );
  });

  testWidgets('헤더를 누르면 펼쳐지고 다시 누르면 접힌다', (tester) async {
    await mount(tester, [make(id: 'a', title: '블로그 글 쓰기')]);

    await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-undated-tile-a')),
      findsOneWidget,
    );
    expect(find.text('블로그 글 쓰기'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-undated-tile-a')), findsNothing);
  });

  testWidgets('완료·메모·날짜 있는 항목은 서랍에 오지 않는다', (tester) async {
    await mount(tester, [
      make(id: 'keep'),
      make(id: 'dated', dueAt: DateTime(2026, 8, 15)),
      make(id: 'done', doneAt: DateTime(2026, 8, 1)),
      make(id: 'note', type: TodoType.note),
    ]);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-undated-tile-keep')),
      findsOneWidget,
    );
    for (final id in ['dated', 'done', 'note']) {
      expect(
        find.byKey(ValueKey('calendar-undated-tile-$id')),
        findsNothing,
        reason: id,
      );
    }
  });

  testWidgets('많이 쌓여도 서랍이 화면을 밀어내지 않는다 (안에서만 스크롤)', (tester) async {
    await mount(tester, [
      for (var i = 0; i < 60; i++) make(id: 'u$i', sortOrder: i),
    ]);
    await tester.tap(find.byKey(const ValueKey('calendar-undated-header')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 상한(200) 안에서만 자리를 차지한다.
    expect(
      tester.getSize(find.byType(ListView)).height,
      lessThanOrEqualTo(200),
    );
  });
}
