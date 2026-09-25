import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/category_providers.dart';
import 'package:solo_todo/src/features/category/category_view.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/home_screen.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/outline_screen.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/ui/app_shell.dart';
import 'package:solo_todo/src/ui/shell_state.dart';

/// Phase 2 — 셸: 그룹 화면 없음, 그룹 머리 = 전체보기 + 그룹 필터, 우클릭 메뉴는 커서 위치.
void main() {
  const ga = Group(id: 'ga', label: '업무', colorValue: 0xFF3366FF);
  final cats = [
    Category.work.copyWith(groupId: 'ga'),
    Category.personalDev,
    Category.daily,
  ];

  setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.desktop);
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Stream<List<Category>>? categories,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiPrefsStoreProvider.overrideWithValue(MemoryUiPrefsStore()),
          watchTodayTodosProvider.overrideWith((_) => Stream.value(<Todo>[])),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          watchTodosByCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          outboxCountProvider.overrideWith((_) => Stream<int>.value(0)),
          allTodosProvider.overrideWith((_) => Stream.value(<Todo>[])),
          rootsOfCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          childrenOfProvider.overrideWith((_, _) => Stream.value(<Todo>[])),
          categoriesProvider.overrideWith(
            (_) => categories ?? Stream.value(cats),
          ),
          groupsProvider.overrideWith((_) => Stream.value(const [ga])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(AppShell)));
  }

  testWidgets('사이드바 그룹 머리 → 전체보기 + 그 그룹 필터', (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('업무').first);
    await tester.pumpAndSettle();

    expect(find.byType(OutlineScreen), findsOneWidget);
    expect(c.read(groupScopeProvider), 'ga');
    expect(c.read(shellLocationProvider), ShellLocation.outline);
  });

  testWidgets('그룹 필터 중 "전체보기" 를 다시 누르면 필터가 풀린다', (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('업무').first);
    await tester.pumpAndSettle();
    expect(c.read(groupScopeProvider), 'ga');

    await tester.tap(find.text('전체보기').first);
    await tester.pumpAndSettle();
    expect(c.read(groupScopeProvider), isNull);
  });

  testWidgets('같은 그룹 머리를 다시 누르면 필터가 풀린다', (tester) async {
    final c = await pump(tester);
    await tester.tap(find.text('업무').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('업무').first);
    await tester.pumpAndSettle();
    expect(c.read(groupScopeProvider), isNull);
  });

  testWidgets('오늘 화면에도 같은 그룹 칩이 있다', (tester) async {
    final c = await pump(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-scope-ga')));
    await tester.pump();
    expect(c.read(groupScopeProvider), 'ga');
  });

  testWidgets('카테고리 우클릭 → 커서 위치 팝업 메뉴', (tester) async {
    await pump(tester);
    await tester.tap(
      find.text(Category.daily.label),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<Object?>), findsNothing);
    expect(find.byKey(const ValueKey('category-menu-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-menu-delete')), findsOneWidget);
    // 바텀시트가 아니라 팝업 — ListTile 이 아니다.
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('보던 카테고리가 사라지면 오늘로 돌아간다', (tester) async {
    final stream = StreamController<List<Category>>.broadcast();
    addTearDown(stream.close);
    final c = await pump(
      tester,
      categories: Stream.multi((m) {
        m.add(cats);
        stream.stream.listen(m.add);
      }),
    );
    c.read(shellLocationProvider.notifier).openCategory('daily');
    await tester.pump();
    expect(find.byType(CategoryView), findsOneWidget);

    // 일상 카테고리가 보관/삭제돼 활성 목록에서 빠진다.
    stream.add([
      for (final x in cats)
        if (x.id != 'daily') x,
    ]);
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget, reason: '즉시 오늘로 그린다');
    await tester.pump(); // 위치 정정은 프레임 뒤
    expect(c.read(shellLocationProvider), ShellLocation.today);
  });
}
