import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/data/providers.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/category_providers.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/home/today_providers.dart';
import 'package:solo_todo/src/features/outline/outline_screen.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/settings/settings_sheet.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/features/todo_detail/todo_detail_screen.dart';
import 'package:solo_todo/src/ui/app_shell.dart';
import 'package:solo_todo/src/ui/widgets/undo_snackbar.dart';

class _Sort implements SortModePreference {
  @override
  Future<TodoSortMode> load() async => TodoSortMode.manual;
  @override
  Future<void> save(TodoSortMode mode) async {}
}

/// Phase 3 — 데스크탑다움: 인스펙터 · ⌘ 단축키 · 사이드바 배지.
void main() {
  final created = DateTime(2026, 9, 20);
  Todo todo(String id, String title, {String? parentId}) => Todo(
    id: id,
    title: title,
    category: Category.work,
    createdAt: created,
    updatedAt: created,
    parentId: parentId,
  );
  final parent = todo('p', '결제 리팩토링');
  final child = todo('c', '에러 코드 확인', parentId: 'p');

  setUp(() => AppPlatform.debugFormFactorOverride = FormFactor.desktop);
  tearDown(() => AppPlatform.debugFormFactorOverride = null);

  Future<void> pump(WidgetTester tester, {List<Todo>? today}) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final all = [parent, child];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiPrefsStoreProvider.overrideWithValue(MemoryUiPrefsStore()),
          sortModePreferenceProvider.overrideWithValue(_Sort()),
          watchTodayTodosProvider.overrideWith(
            (_) => Stream.value(today ?? const <Todo>[]),
          ),
          recurrenceMaterializerProvider.overrideWith((_) {}),
          watchTodosByCategoryProvider.overrideWith(
            (_, _) => Stream.value(<Todo>[]),
          ),
          outboxCountProvider.overrideWith((_) => Stream<int>.value(0)),
          allTodosProvider.overrideWith((_) => Stream.value(all)),
          rootsOfCategoryProvider.overrideWith(
            (_, c) => Stream.value([
              for (final t in all)
                if (t.parentId == null && t.category.id == c.id) t,
            ]),
          ),
          childrenOfProvider.overrideWith(
            (_, pid) => Stream.value([
              for (final t in all)
                if (t.parentId == pid) t,
            ]),
          ),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(const <Group>[])),
        ],
        child: MaterialApp(
          theme: AppTheme.mobileLight(),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> openOutline(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.byType(OutlineScreen), findsOneWidget);
  }

  group('인스펙터', () {
    testWidgets('항목 탭 → 오른쪽 패널, 사이드바·목록은 그대로', (tester) async {
      await pump(tester);
      await openOutline(tester);

      await tester.tap(find.text('결제 리팩토링'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('inspector-panel')), findsOneWidget);
      expect(find.byType(TodoDetailScreen), findsNothing, reason: 'push 아님');
      expect(find.byType(OutlineScreen), findsOneWidget);
      expect(find.byType(TodoDetailView), findsOneWidget);
    });

    testWidgets('패널 안에서 하위로 들어가고 ← 로 돌아온다', (tester) async {
      await pump(tester);
      await openOutline(tester);
      await tester.tap(find.text('결제 리팩토링'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('inspector-panel')),
          matching: find.text('에러 코드 확인'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inspector-back')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('inspector-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inspector-back')), findsNothing);
      expect(find.byKey(const ValueKey('inspector-panel')), findsOneWidget);
    });

    testWidgets('× 와 Esc 로 닫힌다', (tester) async {
      await pump(tester);
      await openOutline(tester);
      await tester.tap(find.text('결제 리팩토링'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inspector-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inspector-panel')), findsNothing);

      await tester.tap(find.text('결제 리팩토링'));
      await tester.pumpAndSettle();
      // 패널 안 입력칸이 아닌 곳에 포커스 — 앱 단축키 Esc.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inspector-panel')), findsNothing);
    });
  });

  group('⌘ 단축키', () {
    testWidgets('⌘1 → 전체보기, ⌘0 → 오늘', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byType(OutlineScreen), findsOneWidget);
    });

    testWidgets('⌘, → 설정', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      // 설정 시트엔 로딩 표시가 돌아 settle 하지 않는다 — 열림만 확인.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsSheet), findsOneWidget);
    });

    testWidgets('⌘Z → 떠 있는 되돌리기 실행', (tester) async {
      await pump(tester);
      var undone = 0;
      showUndoSnackbar(
        tester.element(find.byType(AppShell)),
        message: '삭제됨',
        onUndo: () => undone++,
      );
      await tester.pump();
      expect(hasLatestUndo(), isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(undone, 1);
      expect(hasLatestUndo(), isFalse);
    });
  });

  testWidgets('데스크탑은 떠 있는 버튼 없이 사이드바 "새 할 일"', (tester) async {
    await pump(tester);
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sidebar-new-todo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-todo-title')), findsOneWidget);
  });

  testWidgets('새 할 일을 연달아 열어도 시트는 한 장', (tester) async {
    await pump(tester);
    // 시트가 뜨기 전에 ⌘N 두 번 (전역 ⌘⇧N·메뉴바 연타와 같은 상황).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-todo-title')), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('사이드바 "오늘" 옆 남은 할 일 수', (tester) async {
    await pump(tester, today: [todo('t1', 'a'), todo('t2', 'b')]);
    expect(find.byKey(const ValueKey('sidebar-badge')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('sidebar-badge'))).data,
      '2',
    );
  });

  // Phase 4 — 기기 테스트에서 발견: 오늘 화면에서 날짜 없이 추가하면 곧바로 사라져 보였다.
  testWidgets('오늘 화면에서 ⌘N → 날짜 기본값은 오늘', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    final sheet = tester.widget<AddTodoSheet>(find.byType(AddTodoSheet));
    final now = DateTime.now();
    expect(sheet.initialDueAt, DateTime(now.year, now.month, now.day));
  });

  testWidgets('전체보기에서 ⌘N 은 날짜 없이(둘러보는 화면)', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AddTodoSheet>(find.byType(AddTodoSheet)).initialDueAt,
      isNull,
    );
  });
}
