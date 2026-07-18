import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/category_providers.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/group/group_screen.dart';
import 'package:solo_todo/src/features/home/home_screen.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/timeline/timeline_screen.dart';
import 'package:solo_todo/src/ui/app_shell.dart';

/// 모바일 시스템 뒤로가기(백버튼/제스처) 계단식 동작 검증.
///
/// [AppPlatform.formFactor] 는 `Platform.isMacOS` 로 판정돼 macOS 테스트 호스트에서는
/// 항상 desktop 이므로, [AppPlatform.debugFormFactorOverride] 로 모바일 레이아웃을 강제한다.
void main() {
  setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.mobile);
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  /// 스트림 provider 를 모두 빈 값으로 override 하고 AppShell 을 마운트한다
  /// (app_shell_shortcuts_test 의 pump 와 동일 — Drift/timer 의존 제거).
  Future<void> pump(
    WidgetTester tester, {
    List<Group> groups = const <Group>[],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(groups)),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
  }

  /// 시스템 뒤로가기 = `flutter/navigation` 채널의 `popRoute` 주입.
  Future<void> systemBack(WidgetTester tester) async {
    final message = const JSONMethodCodec().encodeMethodCall(
      const MethodCall('popRoute'),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      message,
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  /// `SystemNavigator.pop` (앱 종료) 호출을 잡아두는 spy 를 건다.
  List<MethodCall> spyAppExit(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return calls;
  }

  testWidgets('Drawer 열림 → 시스템 back → Drawer 닫힘 (앱 종료 X)', (tester) async {
    final exits = spyAppExit(tester);
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('manage-drawer-button')));
    await tester.pumpAndSettle();
    final scaffold = tester.firstState<ScaffoldState>(find.byType(Scaffold));
    expect(scaffold.isDrawerOpen, isTrue, reason: 'back 전에 Drawer 가 열려 있어야 함');

    await systemBack(tester);

    expect(scaffold.isDrawerOpen, isFalse, reason: 'back → Drawer 가 닫혀야 함');
    expect(exits, isEmpty, reason: 'Drawer 닫힘이 back 을 소비 → 앱 종료 호출 없어야 함');
  });

  testWidgets('비-오늘 탭 → 시스템 back → 오늘 복귀 (앱 종료 X)', (tester) async {
    final exits = spyAppExit(tester);
    await pump(tester);
    expect(find.byType(HomeScreen), findsOneWidget, reason: '초기 진입은 오늘');

    // 타임라인 탭으로 이동.
    await tester.tap(find.text('타임라인'));
    await tester.pumpAndSettle();
    expect(find.byType(TimelineScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    await systemBack(tester);

    expect(find.byType(HomeScreen), findsOneWidget, reason: 'back → 오늘 탭 복귀');
    expect(exits, isEmpty, reason: '탭 복귀가 back 을 소비 → 앱 종료 호출 없어야 함');
  });

  testWidgets('그룹 화면 → 시스템 back → 원래 탭 복귀 (앱 종료 X)', (tester) async {
    const g = Group(id: 'grp-test', label: '테스트그룹', colorValue: 0xFF2A66FF);
    final exits = spyAppExit(tester);
    await pump(tester, groups: [g]);

    // Drawer 열고 그룹 진입.
    await tester.tap(find.byKey(const ValueKey('manage-drawer-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('테스트그룹'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupScreen), findsOneWidget, reason: '그룹 화면 진입');

    await systemBack(tester);

    expect(
      find.byType(GroupScreen),
      findsNothing,
      reason: 'back → 그룹 나가고 탭 복귀',
    );
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(exits, isEmpty, reason: '그룹 나가기가 back 을 소비 → 앱 종료 호출 없어야 함');
  });

  testWidgets('오늘 탭(루트) → 시스템 back → 앱 종료 호출', (tester) async {
    final exits = spyAppExit(tester);
    await pump(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    await systemBack(tester);

    expect(
      exits,
      isNotEmpty,
      reason: '루트(오늘)에서는 가로챌 게 없어 앱 종료(SystemNavigator.pop) 로 이어져야 함',
    );
  });
}
