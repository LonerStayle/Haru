import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:solo_todo/src/core/platform.dart';
import 'package:solo_todo/src/core/theme.dart';
import 'package:solo_todo/src/core/ui_prefs.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_default_category.dart';
import 'package:solo_todo/src/features/auth/auth_service.dart';
import 'package:solo_todo/src/features/auth/sign_in_screen.dart';
import 'package:solo_todo/src/features/calendar/google_auth_service.dart';
import 'package:solo_todo/src/features/calendar/microsoft_auth_service.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/category/groups_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';
import 'package:solo_todo/src/features/settings/app_preferences.dart';
import 'package:solo_todo/src/features/settings/archive_screen.dart';
import 'package:solo_todo/src/features/settings/settings_sheet.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';
import 'package:solo_todo/src/features/system/tray_service.dart';
import 'package:tray_manager/tray_manager.dart';

/// UX 개선 Phase 4 — 설정·보관함·로그인·트레이 (개선안 §4-9).
class _MemorySort implements SortModePreference {
  TodoSortMode saved = TodoSortMode.manual;

  @override
  Future<TodoSortMode> load() async => saved;

  @override
  Future<void> save(TodoSortMode mode) async => saved = mode;
}

Todo todo(String id, Category c) => Todo(
  id: id,
  title: id,
  category: c,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('설정', () {
    // 설정 목록은 필요한 만큼만 그리는 ListView 라 아래 항목은 스크롤해야 생긴다.
    Future<void> scrollTo(WidgetTester tester, Finder target) =>
        tester.scrollUntilVisible(
          target,
          200,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('settings-list')),
            matching: find.byType(Scrollable),
          ),
        );

    Future<({MemoryUiPrefsStore prefs, ProviderContainer container})> open(
      WidgetTester tester, {
      FormFactor form = FormFactor.desktop,
    }) async {
      AppPlatform.debugFormFactorOverride = form;
      addTearDown(() => AppPlatform.debugFormFactorOverride = null);
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = MemoryUiPrefsStore();
      final container = ProviderContainer(
        overrides: [
          uiPrefsStoreProvider.overrideWithValue(prefs),
          sortModePreferenceProvider.overrideWithValue(_MemorySort()),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
          groupsProvider.overrideWith((_) => Stream.value(<Group>[])),
          googleCalendarAvailableProvider.overrideWithValue(false),
          microsoftCalendarAvailableProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.mobileLight(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => SettingsSheet.show(context),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return (prefs: prefs, container: container);
    }

    testWidgets('데스크탑은 가운데 대화상자 + 섹션(일반·데이터·정보)', (tester) async {
      await open(tester);
      expect(find.byType(Dialog), findsOneWidget);
      for (final s in ['일반', '데이터', '정보']) {
        await scrollTo(tester, find.byKey(ValueKey('settings-section-$s')));
        expect(find.byKey(ValueKey('settings-section-$s')), findsOneWidget);
      }
      // 캘린더 키가 없는 빌드에선 캘린더 섹션 자체가 없다.
      expect(
        find.byKey(const ValueKey('settings-section-캘린더 연동')),
        findsNothing,
      );
      await scrollTo(tester, find.byKey(const ValueKey('settings-shortcuts')));
      expect(find.byKey(const ValueKey('settings-shortcuts')), findsOneWidget);
    });

    testWidgets('폰은 전체 화면 페이지, 단축키 항목 없음', (tester) async {
      await open(tester, form: FormFactor.mobile);
      expect(find.byType(Dialog), findsNothing);
      expect(find.widgetWithText(AppBar, '설정'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-shortcuts')), findsNothing);
    });

    testWidgets('테마를 다크로 바꾸면 저장된다', (tester) async {
      final r = await open(tester);
      await tester.tap(find.text('다크'));
      await tester.pump();
      expect(r.container.read(themeModeProvider), ThemeMode.dark);
      expect(r.prefs.lists['app.themeMode'], ['dark']);
    });

    testWidgets('목록 정렬을 일정순으로', (tester) async {
      final r = await open(tester);
      await tester.tap(find.text('일정순'));
      await tester.pump();
      expect(r.container.read(sortModeProvider), TodoSortMode.dueDate);
    });

    testWidgets('기본 카테고리 고르기 → 저장', (tester) async {
      final r = await open(tester);
      await tester.tap(find.byKey(const ValueKey('settings-default-category')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(Category.daily.label).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(r.container.read(defaultCategoryIdProvider), Category.daily.id);
      expect(r.prefs.lists['app.defaultCategory'], [Category.daily.id]);
    });

    testWidgets('미리 읽어 둔 테마는 첫 프레임부터 적용된다(깜빡임 없음)', (tester) async {
      final c = ProviderContainer(
        overrides: [
          uiPrefsStoreProvider.overrideWithValue(MemoryUiPrefsStore()),
          preloadedUiListsProvider.overrideWithValue({
            'app.themeMode': ['dark'],
            'app.defaultCategory': ['daily'],
          }),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(themeModeProvider), ThemeMode.dark);
      expect(c.read(defaultCategoryIdProvider), 'daily');
    });

    testWidgets('단축키 목록 창', (tester) async {
      await open(tester);
      await scrollTo(tester, find.byKey(const ValueKey('settings-shortcuts')));
      await tester.tap(find.byKey(const ValueKey('settings-shortcuts')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('settings-shortcuts-dialog')),
        findsOneWidget,
      );
      expect(find.text('⌘⇧N'), findsOneWidget);
    });

    testWidgets('반복 일정 진입점이 설정에 있다', (tester) async {
      await open(tester);
      await scrollTo(tester, find.byKey(const ValueKey('settings-recurrence')));
      expect(find.byKey(const ValueKey('settings-recurrence')), findsOneWidget);
    });
  });

  group('기본 카테고리 적용', () {
    test('카테고리 화면이 아니면 설정의 기본 카테고리', () {
      final c = resolveAddTodoDefaultCategory(
        categories: Category.builtinSeeds,
        groups: const [],
        destinations: const [],
        index: 0,
        selectedGroupId: null,
        preferredCategoryId: Category.daily.id,
      );
      expect(c.id, Category.daily.id);
    });

    test('보관·삭제돼 목록에 없는 기본값은 무시하고 첫 카테고리', () {
      final c = resolveAddTodoDefaultCategory(
        categories: Category.builtinSeeds,
        groups: const [],
        destinations: const [],
        index: 0,
        selectedGroupId: null,
        preferredCategoryId: 'gone',
      );
      expect(c.id, Category.builtinSeeds.first.id);
    });
  });

  group('보관함', () {
    const g = Group(
      id: 'g-old',
      label: '지난회사',
      colorValue: 0xFF2A66FF,
      archived: true,
    );
    final inGroup = Category.work.copyWith(groupId: 'g-old', archived: true);
    final standalone = Category.idea.copyWith(archived: true);

    Future<void> pump(
      WidgetTester tester, {
      List<Todo> todos = const [],
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            categoriesProvider.overrideWith(
              (_) => Stream.value([inGroup, standalone, Category.daily]),
            ),
            groupsProvider.overrideWith((_) => Stream.value(const [g])),
            allTodosProvider.overrideWith((_) => Stream.value(todos)),
          ],
          child: MaterialApp(
            theme: AppTheme.mobileLight(),
            home: const ArchiveScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('그룹을 펼치면 안의 카테고리와 할 일 수, "이것만 꺼내기"', (tester) async {
      await pump(tester, todos: [todo('t1', inGroup), todo('t2', inGroup)]);
      expect(find.text('카테고리 1개 · 할 일 2개'), findsOneWidget);
      await tester.tap(find.text('지난회사'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('restore-cat-only-${inGroup.id}')),
        findsOneWidget,
      );
    });

    testWidgets('할 일이 남은 카테고리는 영구 삭제를 막고 이유를 알린다', (tester) async {
      await pump(tester, todos: [todo('t1', standalone)]);
      await tester.tap(find.byKey(ValueKey('delete-cat-${standalone.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영구 삭제'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('archive-delete-confirm')),
        findsNothing,
      );
      expect(find.textContaining('할 일 1개가 남아 있어'), findsOneWidget);
    });

    testWidgets('빈 카테고리는 확인을 받고 지운다', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(ValueKey('delete-cat-${standalone.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영구 삭제'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('archive-delete-confirm')),
        findsOneWidget,
      );
    });
  });

  group('트레이 메뉴', () {
    TrayService service({List<String>? toggled, List<String>? calls}) =>
        TrayService(
          onOpen: () => calls?.add('open'),
          onAddTodo: () => calls?.add('add'),
          onOpenSettings: () => calls?.add('settings'),
          onToggleTodo: (id) => toggled?.add(id),
          onQuit: () => calls?.add('quit'),
        );

    List<MenuItem> items(Menu m) => m.items ?? const [];

    test('하루 열기 · 남은 할 일(누르면 완료) · 새 할 일 · 설정 · 동기화 상태 · 종료', () {
      final toggled = <String>[];
      final calls = <String>[];
      final menu = service(toggled: toggled, calls: calls).buildMenu(
        const TrayState(
          top: [
            TrayTodo(id: 'a', title: '보고서'),
            TrayTodo(id: 'b', title: '회의', inProgress: true),
          ],
          undoneCount: 7,
          pendingSync: 2,
        ),
      );
      final labels = [for (final i in items(menu)) i.label];
      expect(labels, contains('하루 열기'));
      expect(labels, contains('오늘 남은 7건 · 누르면 완료'));
      expect(labels, contains('○  보고서'));
      expect(labels, contains('◐  회의'));
      expect(labels, contains('외 5건 — 하루에서 보기'));
      expect(labels, contains('새 할 일 (⌘⇧N)'));
      expect(labels, contains('설정… (⌘,)'));
      expect(labels, contains('동기화 대기 2건'));

      items(menu).firstWhere((i) => i.key == 'todo:a').onClick!(
        items(menu).first,
      );
      expect(toggled, ['a']);
      items(menu).firstWhere((i) => i.key == 'settings').onClick!(
        items(menu).first,
      );
      expect(calls, ['settings']);
    });

    test('남은 게 없으면 "없음", 동기화됨', () {
      final labels = [
        for (final i in items(service().buildMenu(const TrayState()))) i.label,
      ];
      expect(labels, contains('오늘 남은 할 일 없음'));
      expect(labels, contains('동기화됨'));
    });

    test('긴 제목은 메뉴에서 줄인다', () {
      final menu = service().buildMenu(
        TrayState(
          top: [TrayTodo(id: 'x', title: '가' * 60)],
          undoneCount: 1,
        ),
      );
      final label = items(menu).firstWhere((i) => i.key == 'todo:x').label!;
      expect(label.length, lessThan(40));
      expect(label, endsWith('…'));
    });
  });

  group('로그인', () {
    Future<_Auth> mount(WidgetTester tester) async {
      final fake = _Auth();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authServiceProvider.overrideWithValue(fake)],
          child: MaterialApp(
            theme: AppTheme.mobileLight(),
            home: const SignInScreen(),
          ),
        ),
      );
      return fake;
    }

    testWidgets('자릿수를 단정하지 않는 문구 + 브랜드 아이콘', (tester) async {
      await mount(tester);
      expect(find.text('이메일로 로그인 코드를 보내 드릴게요.'), findsOneWidget);
      expect(find.textContaining('6자리'), findsNothing);
      expect(find.byKey(const ValueKey('sign-in-brand')), findsOneWidget);
    });

    testWidgets('코드 다시 받기는 60초 뒤에 열린다', (tester) async {
      final fake = await mount(tester);
      await tester.enterText(find.byType(TextField).first, 'me@example.com');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '코드 받기'));
      await tester.pump();
      await tester.pump();
      expect(find.text('코드 다시 받기 (60초)'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('sign-in-resend')))
            .onPressed,
        isNull,
      );

      await tester.pump(const Duration(seconds: 61));
      expect(find.text('코드 다시 받기'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sign-in-resend')));
      await tester.pump();
      await tester.pump();
      expect(fake.sent, 2);
      expect(find.text('코드 다시 받기 (60초)'), findsOneWidget);
    });

    testWidgets('오류는 입력칸 아래에(errorText), 해요체', (tester) async {
      final fake = await mount(tester)
        ..fail = true;
      await tester.enterText(find.byType(TextField).first, 'me@example.com');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '코드 받기'));
      await tester.pump();
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.decoration?.errorText, contains('다시 시도해 주세요'));
      expect(fake.sent, 1);
    });
  });
}

class _Auth implements AuthService {
  int sent = 0;
  bool fail = false;

  @override
  Future<void> sendEmailOtp(String email) async {
    sent++;
    if (fail) throw const AuthException('rate limit', statusCode: '429');
  }

  @override
  Future<AuthResponse> verifyEmailOtp({
    required String email,
    required String token,
  }) async => throw UnimplementedError();

  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
