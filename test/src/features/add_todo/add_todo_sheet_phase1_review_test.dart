import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';

import '../../../helpers/add_todo_sheet_helpers.dart';

/// UX Phase 1 시트 리뷰 반영 — 열었다 닫기만 하면 아무것도 바뀌지 않아야 하고,
/// 새 흐름(날짜 → 시간 → 종료)이 이미 넣은 값을 잃지 않아야 한다.
void main() {
  Todo item({
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
  }) => Todo(
    id: 'e',
    title: '열었다 닫기',
    category: Category.work,
    dueAt: dueAt,
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
    createdAt: DateTime.utc(2026, 9, 20),
    updatedAt: DateTime.utc(2026, 9, 20),
  );

  /// 편집 시트를 열고 → (선택) [act] → 배경 탭으로 닫는다. 닫힘 저장 결과를 돌려준다.
  Future<List<Todo>> openAndClose(
    WidgetTester tester,
    Todo initial, {
    Future<void> Function()? act,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
                  key: const ValueKey('open'),
                  onPressed: () => AddTodoSheet.show(
                    context,
                    initialCategory: Category.work,
                    initialTodo: initial,
                    onSubmit: (_) {},
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
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    if (act != null) await act();
    await tester.tapAt(const Offset(10, 10)); // 배경 탭 = 닫힘 저장
    await tester.pumpAndSettle();
    return updates;
  }

  group('열었다 닫기 = 아무것도 안 바뀜', () {
    testWidgets('다른 기기에서 온(UTC) 종일 항목 — 날짜가 하루 당겨지지 않는다', (tester) async {
      // 로컬 9/25 자정을 UTC 로 표현한 값 (동기화로 들어온 모양).
      final localMidnight = DateTime(2026, 9, 25);
      final original = item(dueAt: localMidnight.toUtc(), isAllDay: true);
      final updates = await openAndClose(tester, original);
      expect(updates, hasLength(1));
      expect(updates.single.dueAt, original.dueAt, reason: '원본 인스턴스 그대로');
      expect(updates.single, original);
    });

    testWidgets('UTC 종일 기간 — 양 끝 그대로', (tester) async {
      final original = item(
        dueAt: DateTime(2026, 9, 25).toUtc(),
        endAt: DateTime(2026, 9, 27).toUtc(),
        isAllDay: true,
      );
      final updates = await openAndClose(tester, original);
      expect(updates.single, original);
    });

    testWidgets('종일 + 마감 기준(캘린더에서 온 조합) — 기준 필드 보존', (tester) async {
      final original = item(
        dueAt: DateTime(2026, 9, 25),
        isAllDay: true,
        timeAnchor: 'end',
      );
      final updates = await openAndClose(tester, original);
      expect(updates.single, original);
    });

    testWidgets('일정 없음 + 종일 표시 — 종일 필드 보존', (tester) async {
      final original = item(isAllDay: true);
      final updates = await openAndClose(tester, original);
      expect(updates.single, original);
    });
  });

  group('새 흐름이 넣은 값을 잃지 않는다', () {
    testWidgets('시간을 정한 뒤 종료 추가 → 시간 유지한 1시간 기간', (tester) async {
      final original = item(dueAt: DateTime(2026, 9, 25, 14, 30));
      final updates = await openAndClose(
        tester,
        original,
        act: () async {
          await openSheetMore(tester);
          await tester.tap(find.byKey(const ValueKey('add-todo-add-end')));
          await tester.pumpAndSettle();
        },
      );
      final saved = updates.single;
      expect(saved.dueAt, DateTime(2026, 9, 25, 14, 30));
      expect(saved.endAt, DateTime(2026, 9, 25, 15, 30));
      expect(saved.isAllDay, isFalse);
    });

    testWidgets('시간 있는 일정에서 같은 날짜 칩을 다시 눌러도 일정이 지워지지 않는다', (tester) async {
      final today = DateTime.now();
      final original = item(
        dueAt: DateTime(today.year, today.month, today.day, 14, 30),
      );
      final updates = await openAndClose(
        tester,
        original,
        act: () async {
          await tester.tap(find.byKey(const ValueKey('quick-due-today')));
          await tester.pump();
        },
      );
      expect(updates.single.dueAt, original.dueAt);
    });
  });

  testWidgets('카테고리 메뉴가 열린 채 Esc → 메뉴만 닫히고 시트는 유지', (tester) async {
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
              builder: (context) => ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () => AddTodoSheet.show(context, onSubmit: (_) {}),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('add-todo-title')), 'abc');
    await tester.tap(find.byKey(const ValueKey('add-todo-category')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-chip-work')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-chip-work')), findsNothing);
    expect(find.byKey(const ValueKey('add-todo-title')), findsOneWidget);
    expect(find.text('abc'), findsOneWidget);
  });
}
