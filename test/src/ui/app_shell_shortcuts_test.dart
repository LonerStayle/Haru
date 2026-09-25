import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/category_providers.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/ui/app_shell.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 모든 stream provider 를 빈 stream 으로 override — Drift 의존 + timer leak 제거.
          // HANDOFF § 6 함정: 'Widget test 에서 Drift stream 직접 사용 금지'.
          watchTodayTodosProvider.overrideWith((_) => Stream.value(<Todo>[])),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          watchTodosByCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          outboxCountProvider.overrideWith((_) => Stream<int>.value(0)),
          // v1.1 — outline screen 용 stream 들.
          allTodosProvider.overrideWith((_) => Stream.value(<Todo>[])),
          rootsOfCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          childrenOfProvider.overrideWith((_, _) => Stream.value(<Todo>[])),
          // v1.2 — AppShell 이 categoriesProvider 를 watch (sidebar dynamic).
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          // v1.3 — AppShell 이 groupsProvider 를 watch (사이드바 그룹 섹션).
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('초기 진입은 Today (오늘 헤더 표시)', (tester) async {
    await pump(tester);
    expect(find.text('오늘'), findsAtLeastNWidgets(1));
  });

  // v1.4 (Task G) — 단축키 재배치: today=0, outline=1, 카테고리 2~6.
  testWidgets('숫자 2 키 → work 카테고리 헤더 노출', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(find.text('회사 할일'), findsAtLeastNWidgets(1));
  });

  testWidgets('숫자 4 키 → daily 카테고리 헤더 노출', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.pump();
    expect(find.text('일상'), findsAtLeastNWidgets(1));
  });

  testWidgets('숫자 6 → idea 로 이동 후 0 → Today 복귀', (tester) async {
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit6);
    await tester.pump();
    expect(find.text('아이디어'), findsAtLeastNWidgets(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.pump();
    expect(find.text('오늘'), findsAtLeastNWidgets(1));
  });

  testWidgets('v1.4 — 숫자 1 → Outline (전체보기) 화면 노출', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();
    expect(find.text('그룹 · 카테고리별 할 일과 메모를 한눈에'), findsOneWidget);
  });

  testWidgets('앱 안 ⌘N → 곧바로 새 할 일 시트 (선택 시트 없이)', (tester) async {
    // 2026-09-24 — 전역은 ⌘⇧N(다른 앱 ⌘N 비충돌), 앱 안은 ⌘N.
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-todo-title')), findsOneWidget);
    expect(find.text('무엇을 추가할까요?'), findsNothing);
  });
}
