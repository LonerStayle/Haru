import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/remote/supabase_realtime_sync.dart';
import '../domain/category.dart';
import '../domain/group.dart';
import '../domain/todo.dart';
import '../features/add_todo/add_todo_controller.dart';
import '../features/add_todo/add_todo_default_category.dart';
import '../features/auth/auth_providers.dart';
import '../features/calendar/calendar_providers.dart';
import '../features/category/categories_controller.dart';
import '../features/category/groups_controller.dart';
import '../features/calendar_view/calendar_providers.dart'
    show calendarSelectionProvider;
import '../features/calendar_view/calendar_screen.dart';
import '../features/category/category_view.dart';
import '../features/home/home_screen.dart';
import '../features/home/today_providers.dart';
import '../features/manage/category_list_screen.dart';
import '../features/category/category_actions.dart';
import '../core/ui_prefs.dart';
import '../features/outline/outline_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/app_preferences.dart';
import '../features/todo_actions/todo_row_actions.dart';
import '../features/settings/archive_screen.dart';
import '../features/settings/settings_sheet.dart';
import '../features/system/tray_service.dart';
import '../features/system/window_service.dart';
import '../features/todo_actions/todo_actions_controller.dart';
import 'destination.dart';
import 'inspector.dart';
import 'shell_state.dart';
import 'widgets/group_scope_chips.dart';
import 'widgets/undo_snackbar.dart';
import 'widgets/add_entity_buttons.dart';

/// 폼팩터 분기 컨테이너 + FAB (빠른 추가 트리거) + destination 숫자 단축키.
///
/// 단축키: `0` = 오늘, `1` = 전체보기, `2` = 캘린더, `3~9` = 카테고리 앞 7개
/// ([AppDestination.buildAll] 이 단일 출처).
///
/// **새 할 일 단축키** (2026-09-24 대표님 결정):
///   - 전역(OS 어디서든) = **⌘⇧N** (`hotkey_manager`, [HotKeyScope.system]).
///     예전엔 전역 ⌘N 이라 하루가 켜져 있으면 Finder·브라우저·에디터의 "새 창/새 파일"
///     ⌘N 을 가로챘다.
///   - 앱 안 = **⌘N** (Flutter [Shortcuts]) — 하루 창이 앞에 있을 때만.
///
/// **시스템 단축키 비충돌 점검** (macOS):
///   - Cmd+W / Cmd+Q / Cmd+M / Cmd+H / Cmd+, 등은 macOS 가 그대로 처리하도록 둠.
///   - 숫자키는 modifier 없는 plain digit — TextField focus 시 [isFocusInEditableText]
///     가드로 숫자 입력에 양보.
///   - Esc 는 AddTodoSheet 의 _DismissIntent (sheet 닫기) — macOS 관행과 일치.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  HotKey? _cmdN;
  TrayService? _tray;

  /// 데스크탑 오른쪽 인스펙터(할 일 상세 패널) 스택.
  final InspectorController _inspector = InspectorController();

  @override
  void initState() {
    super.initState();
    _registerGlobalHotkey();
    _initTray();
    _inspector.addListener(_onInspectorChanged);
  }

  void _onInspectorChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _inspector
      ..removeListener(_onInspectorChanged)
      ..dispose();
    _unregisterGlobalHotkey();
    _tray?.dispose();
    super.dispose();
  }

  Future<void> _initTray() async {
    if (!AppPlatform.isDesktop) return;
    final tray = TrayService(
      onOpen: () => const WindowService().showMainWindow(),
      onAddTodo: () async {
        await const WindowService().showMainWindow();
        if (mounted) _openAddTodo();
      },
      onOpenSettings: () async {
        await const WindowService().showMainWindow();
        if (mounted) _openSettings();
      },
      onToggleTodo: _toggleFromTray,
      onQuit: () {
        if (mounted) _confirmQuit();
      },
    );
    await tray.init();
    if (!mounted) {
      await tray.dispose();
      return;
    }
    _tray = tray;
    _pushTrayState();
  }

  /// 트레이에서 할 일 완료 — 창을 띄우지 않고 바로 체크. 되돌리려면 앱에서 다시
  /// 체크를 풀면 된다(트레이엔 되돌리기 스낵바가 없다).
  Future<void> _toggleFromTray(String id) async {
    final todo = ref
        .read(undoneTodayTodosProvider)
        .where((t) => t.id == id)
        .firstOrNull;
    if (todo == null) return;
    await ref.read(todoActionsProvider).toggle(todo);
  }

  void _pushTrayState() {
    final tray = _tray;
    if (tray == null) return;
    final undone = ref.read(undoneTodayTodosProvider);
    tray.update(
      TrayState(
        top: [
          for (final t in undone.take(trayTopLimit))
            TrayTodo(id: t.id, title: t.title, inProgress: t.isInProgress),
        ],
        undoneCount: undone.length,
        pendingSync: ref.read(outboxCountProvider).value ?? 0,
      ),
    );
  }

  /// tray menu 의 "종료" — outbox 가 비어 있으면 즉시 종료, pending 이 있으면 confirm dialog.
  /// 동기화되지 않은 변경은 다음 실행 시 자동 flush 되지만, 사용자가 그 사실을 알 수 있게.
  Future<void> _confirmQuit() async {
    final pending = ref.read(outboxCountProvider).value ?? 0;
    if (pending == 0) {
      await SystemNavigator.pop();
      return;
    }
    if (!mounted) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('종료할까요?'),
            content: Text(
              '아직 동기화되지 않은 변경 $pending건이 있어요.\n'
              '다음 실행 시 자동 동기화되지만 지금 끄면 잠시 동안 다른 기기에서 안 보일 수 있어요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('종료'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) {
      await SystemNavigator.pop();
    }
  }

  Future<void> _registerGlobalHotkey() async {
    if (!AppPlatform.isDesktop) return;
    try {
      // `unregisterAll()` 은 hotkey_manager 의 process-scope 모든 hotkey 를 제거한다.
      // 다른 앱 영향은 없지만, 만약 향후 우리 앱이 hotkey 를 추가하면 함께 날아갈 위험이
      // 있어 **정확히 우리 단축키만** unregister 후 register 하는 형태로 안전화.
      // 전역은 ⌘⇧N — 다른 앱의 ⌘N(새 창/새 파일)을 가로채지 않는다 (대표님 결정
      // 2026-09-24). 앱 안의 ⌘N 은 _ShortcutsHost 가 따로 처리한다.
      final hotkey = HotKey(
        key: PhysicalKeyboardKey.keyN,
        modifiers: const [HotKeyModifier.meta, HotKeyModifier.shift],
        scope: HotKeyScope.system,
      );
      try {
        await hotKeyManager.unregister(hotkey);
      } catch (_) {
        // 등록 안 되어 있으면 무시 — register 만 진행.
      }
      await hotKeyManager.register(
        hotkey,
        keyDownHandler: (_) async {
          // 창이 다른 앱 뒤에 있으면 시트가 안 보인다 — 먼저 앞으로.
          await const WindowService().showMainWindow();
          if (mounted) _openAddTodo();
        },
      );
      _cmdN = hotkey;
    } catch (e) {
      // 글로벌 단축키 등록 실패 (test 환경 / 권한 거부) — FAB 으로 대체 가능하므로 fatal X.
      debugPrint('[haru] ⌘⇧N 전역 단축키 등록 실패: $e');
    }
  }

  Future<void> _unregisterGlobalHotkey() async {
    final h = _cmdN;
    if (h == null) return;
    try {
      await hotKeyManager.unregister(h);
    } catch (_) {
      // 종료 단계 — 무시.
    }
  }

  /// build 마다 갱신되는 destinations — categoriesProvider 의 stream 으로 동기화.
  /// _selectByDigit / _openAddTodo 가 참조한다.
  List<AppDestination> _destinations = AppDestination.all;

  ShellLocationNotifier get _nav => ref.read(shellLocationProvider.notifier);

  void _go(ShellLocation location) => _nav.go(location);

  /// destination index → 이동 (사이드바 · 하단 네비 · 숫자키).
  ///
  /// 지금 보고 있는 오늘/전체보기를 **다시** 고르면 그룹 필터를 푼다 — "전체보기" 를
  /// 눌렀는데 한 그룹만 보이는 막다른 길을 없앤다. (오늘↔전체보기 사이 이동은 필터
  /// 유지 — 두 화면이 같은 그룹을 공유한다.)
  void _select(int i) {
    if (i < 0 || i >= _destinations.length) return;
    final next = ShellLocation.of(_destinations[i]);
    final scoped =
        next.page == ShellPage.today || next.page == ShellPage.outline;
    if (scoped && ref.read(shellLocationProvider) == next) {
      ref.read(groupScopeProvider.notifier).set(null);
    }
    _go(next);
  }

  /// 사이드바 그룹 머리 탭 → 전체보기 + 그 그룹 필터 (예전 그룹 화면 대체).
  /// 이미 그 그룹을 보고 있으면 필터를 푼다(토글).
  void _openGroup(String groupId) {
    final scope = ref.read(groupScopeProvider.notifier);
    final location = ref.read(shellLocationProvider);
    final onScoped =
        location.page == ShellPage.today || location.page == ShellPage.outline;
    if (onScoped && ref.read(groupScopeProvider) == groupId) {
      scope.set(null);
      return;
    }
    scope.set(groupId);
    _go(ShellLocation.outline);
  }

  /// 카테고리 화면의 상위 — 들어온 곳(전체보기) 또는 카테고리 목록.
  ShellLocation get _categoryParent =>
      _nav.returnTo ??
      (AppPlatform.isMobile ? ShellLocation.categories : ShellLocation.today);

  /// 지금 위치가 가리키는 destination 의 index. 카테고리가 사라졌으면 -1.
  int _indexOf(ShellLocation location) {
    if (location.page == ShellPage.categories) return -1;
    return _destinations.indexWhere(location.matches);
  }

  /// 모바일 시스템 뒤로가기(백버튼/제스처)로 "가로챌 것" 이 있는지.
  ///
  /// true 면 [PopScope.canPop] = false 로 두어 OS 에 "이 back 은 내가 처리한다" 를 알리고
  /// (predictive-back 제스처도 앱 종료 대신 우리 핸들러로 라우팅됨), [_handleMobileBack]
  /// 이 계단식으로 소비한다. 오늘이 아니면 전부 가로챈다.
  ///
  /// 데스크탑은 시스템 뒤로가기가 없으므로 항상 false (PopScope 무력화).
  bool _mobileHasBackTarget(ShellLocation location) =>
      AppPlatform.isMobile && location.page != ShellPage.today;

  /// 모바일 시스템 뒤로가기 계단:
  ///   1) 카테고리 화면 → 들어온 곳(전체보기) 또는 카테고리 목록
  ///   2) 그 밖의 비-오늘 화면 → 오늘
  /// (오늘이면 canPop=true 라 여기 오지 않음 → 그때만 OS 가 앱을 종료.)
  void _handleMobileBack() {
    final location = ref.read(shellLocationProvider);
    if (location.page == ShellPage.category) {
      _go(_categoryParent);
      return;
    }
    if (location.page != ShellPage.today) _go(ShellLocation.today);
  }

  /// 단축키 digit (0~9) → destination. 매칭 못 하면 no-op.
  void _selectByDigit(int digit) {
    final idx = _destinations.indexWhere((d) => d.shortcutDigit == digit);
    if (idx >= 0) _select(idx);
  }

  /// 검색이 떠 있는 중 — ⌘K 를 연달아 눌러도 한 장만.
  bool _searchOpen = false;

  /// 전역 검색 열기 — 사이드바/앱바 버튼과 ⌘K·⌘F 가 공유하는 단일 진입점.
  ///
  /// 데스크탑 오버레이에서 결과를 열면 그 카테고리 화면으로 가서 오른쪽 인스펙터에
  /// 띄운다(목록 속 위치와 내용을 함께 보게). ⌘↩ 는 편집 시트.
  Future<void> _openSearch() async {
    if (!mounted || _searchOpen) return;
    _searchOpen = true;
    try {
      await SearchScreen.show(
        context,
        onReveal: (todo) {
          ref
              .read(shellLocationProvider.notifier)
              .openCategory(todo.category.id);
          _inspector.open(todo);
        },
        onEdit: (todo) {
          if (mounted) openTodoEdit(context, ref, todo);
        },
      );
    } finally {
      _searchOpen = false;
    }
  }

  /// FAB / Cmd+N / 트레이 공통 진입점 — **곧바로 새 할 일 시트**를 연다.
  ///
  /// 기본 카테고리 = "지금 보고 있는 화면" 기준: 카테고리 화면이면 그 카테고리,
  /// 오늘·전체보기에서 그룹 필터가 켜져 있으면 그 그룹의 첫 카테고리.
  /// 추가 시트가 떠 있는 중 — 전역 ⌘⇧N·메뉴바·트레이를 연달아 눌러도 한 장만.
  bool _addSheetOpen = false;

  /// 설정 시트가 떠 있는 중 — ⌘, · 메뉴바 · 버튼을 연달아 눌러도 한 장만.
  bool _settingsOpen = false;

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      await SettingsSheet.show(context);
    } finally {
      _settingsOpen = false;
    }
  }

  Future<void> _openAddTodo() async {
    if (_addSheetOpen) return;
    final categories =
        ref.read(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    final groups =
        ref.read(activeGroupsProvider).asData?.value ?? const <Group>[];
    final location = ref.read(shellLocationProvider);
    final scoped =
        location.page == ShellPage.today || location.page == ShellPage.outline;
    final initialCategory = resolveAddTodoDefaultCategory(
      categories: categories,
      groups: groups,
      destinations: _destinations,
      index: _indexOf(location),
      selectedGroupId: scoped ? ref.read(groupScopeProvider) : null,
      preferredCategoryId: ref.read(defaultCategoryIdProvider),
      lastUsedId: ref.read(lastUsedCategoryProvider),
    );

    // 기본 날짜 — 캘린더 화면이면 거기서 고른 날, 오늘 화면이면 오늘.
    // '오늘' 은 날짜가 있는 항목만 보여 주므로(v1.5), 오늘 화면에서 날짜 없이 추가하면
    // 방금 추가한 항목이 곧바로 사라져 보였다(Phase 4 기기 테스트에서 발견).
    final now = ref.read(nowProvider)();
    final calendarDay = switch (location.page) {
      ShellPage.calendar => ref.read(calendarSelectionProvider).selectedDay,
      ShellPage.today => DateTime(now.year, now.month, now.day),
      _ => null,
    };

    _addSheetOpen = true;
    try {
      await showNewTodoSheet(
        context,
        ref,
        initialCategory: initialCategory,
        initialDueAt: calendarDay,
      );
    } finally {
      _addSheetOpen = false;
    }
  }

  /// 모바일 하단 바 — `[오늘, 전체보기, 캘린더, 카테고리]` 4칸 고정.
  ///
  /// 4번째 칸은 카테고리 **목록 화면**이다(예전엔 관리 Drawer 를 열었다). 카테고리
  /// 화면에 들어가 있으면 그 칸이 선택된 채 라벨·아이콘이 그 카테고리로 바뀐다.
  Widget _buildMobileNavBar(ShellLocation location, AppDestination? current) {
    // 전체보기에서 들어온 카테고리 화면은 전체보기 칸을 유지한다(돌아갈 곳과 일치).
    final fromOutline =
        location.page == ShellPage.category &&
        _nav.returnTo == ShellLocation.outline;
    final navSelected = switch (location.page) {
      ShellPage.today => 0,
      ShellPage.outline => 1,
      ShellPage.calendar => 2,
      ShellPage.category when fromOutline => 1,
      ShellPage.categories || ShellPage.category => 3,
    };
    final onCategory =
        location.page == ShellPage.category && current != null && !fromOutline;

    return NavigationBar(
      selectedIndex: navSelected,
      onDestinationSelected: (i) => _go(switch (i) {
        0 => ShellLocation.today,
        1 => ShellLocation.outline,
        2 => ShellLocation.calendar,
        _ => ShellLocation.categories,
      }),
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.today_outlined),
          label: '오늘',
        ),
        const NavigationDestination(
          icon: Icon(Icons.account_tree_outlined),
          label: '전체보기',
        ),
        const NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          label: '캘린더',
        ),
        NavigationDestination(
          icon: Icon(onCategory ? current.icon : Icons.category_outlined),
          label: onCategory ? current.label : '카테고리',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 미체크 카운트가 바뀌면 tray title 갱신 (macOS 만 실효).
    // 오늘 남은 할 일·동기화 대기가 바뀌면 트레이 제목·메뉴 갱신 (macOS 만 실효).
    ref.listen<List<Todo>>(
      undoneTodayTodosProvider,
      (_, _) => _pushTrayState(),
    );
    ref.listen(outboxCountProvider, (_, _) => _pushTrayState());

    // Supabase realtime sync — 인증된 user 가 있을 때만 활성. lifecycle 은 provider 가 관리.
    ref.watch(supabaseRealtimeSyncProvider);

    // user 가 다른 계정으로 바뀌면 옛 todos/outbox 자동 정리 (side-effect listener).
    ref.watch(userChangeCleanupProvider);

    // Google Calendar 자동 동기화 — 앱 시작·포그라운드 복귀·5분 주기.
    // 연동이 꺼져 있거나 OAuth 키가 없으면 scheduler 자체가 null 이라 아무 일도 없다.
    ref.watch(calendarSyncSchedulerProvider)?.start();

    // v1.2 — 활성 카테고리 stream 에 따라 destinations 동적 build (보관 카테고리 제외).
    // loading / error 시 fallback 으로 builtin 5종 기준의 default 사용.
    // ⌘N 기본값(마지막에 쓴 카테고리)을 앱 시작 때 미리 복원해 둔다 — 값이 바뀌어도
    // 셸을 다시 그릴 필요는 없어 listen 으로 살려 두기만 한다.
    ref.listen(lastUsedCategoryProvider, (_, _) {});
    // "마지막에 쓴" = 새 할 일을 추가한 카테고리 + 마지막으로 연 카테고리 화면(대표님 결정,
    // 2026-09-25). Bxg 를 보다가 오늘로 와서 ⌘N 해도 Bxg 로 열린다.
    ref.listen(shellLocationProvider, (_, next) {
      final id = next.categoryId;
      if (next.page == ShellPage.category && id != null) {
        ref.read(lastUsedCategoryProvider.notifier).record(id);
      }
    });
    final categoriesAsync = ref.watch(activeCategoriesProvider);
    // value — 이전 값을 든 채 loading/error 일 때도 실제 목록 유지 (asData 면 기본 목록으로
    // 떨어져, 보고 있던 사용자 카테고리가 "사라졌다" 로 오판돼 화면이 튕긴다).
    final categories = categoriesAsync.value ?? Category.builtinSeeds;

    // v1.3 — 활성 그룹 stream. 사이드바가 그룹 헤더 + 미분류 섹션으로 카테고리를 묶는다.
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    // 목적지 순서 = 사이드바에 보이는 순서(그룹 → 카테고리, 미분류는 아래). 숫자 단축키
    // 3~9 도 이 순서로 붙는다 — 카테고리 sortOrder 만 쓰면 그룹이 생긴 뒤 맨 위 카테고리가
    // 9번이 되는 식으로 보이는 순서와 번호가 뒤섞였다.
    _destinations = AppDestination.buildAll(
      categoriesInSidebarOrder(categories, groups),
    );

    var location = ref.watch(shellLocationProvider);
    // 데스크탑엔 카테고리 목록 화면이 없다(사이드바가 그 역할) → 오늘로.
    if (location.page == ShellPage.categories && AppPlatform.isDesktop) {
      location = ShellLocation.today;
    }
    var index = _indexOf(location);
    // 보고 있던 카테고리가 삭제·보관되면 — 모바일은 카테고리 목록, 데스크탑은 오늘로.
    // (로딩 중 fallback 목록에서 못 찾은 경우는 제외 — 실제 목록이 올 때까지 기다린다.)
    if (location.page == ShellPage.category && index < 0) {
      final fallback = AppPlatform.isMobile
          ? ShellLocation.categories
          : ShellLocation.today;
      if (categoriesAsync.hasValue) {
        final gone = location;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && ref.read(shellLocationProvider) == gone) {
            _go(fallback);
          }
        });
      }
      location = fallback;
      index = _indexOf(location);
    }
    final AppDestination? destination = index >= 0
        ? _destinations[index]
        : null;

    final scopedGroupId = ref.watch(scopedGroupProvider)?.id;

    final Widget mainContent = switch (location.page) {
      ShellPage.categories => CategoryListScreen(
        onSelectCategory: (c) => _go(ShellLocation.category(c.id)),
        onOpenGroup: (g) => _openGroup(g.id),
      ),
      _ => _MainArea(destination: destination ?? _destinations.first),
    };

    // 모바일만 떠 있는 원형 버튼 (endFloat 가 네비 바 위로 띄움). 데스크탑은 오른쪽
    // 인스펙터를 가리지 않도록 떠 있는 버튼 없이 사이드바 위 "새 할 일" + ⌘N (Phase 3).
    final Widget? fab = AppPlatform.isDesktop
        ? null
        : FloatingActionButton(
            key: const ValueKey('add-todo-fab'),
            onPressed: _openAddTodo,
            tooltip: '새 할 일',
            child: const Icon(Icons.add),
          );

    final Widget body;
    if (AppPlatform.isDesktop) {
      final onScopedPage =
          location.page == ShellPage.today ||
          location.page == ShellPage.outline;
      body = Row(
        children: [
          _Sidebar(
            destinations: _destinations,
            groups: groups,
            selectedIndex: index,
            selectedGroupId: onScopedPage ? scopedGroupId : null,
            onSelect: _select,
            onSelectGroup: _openGroup,
            onAddTodo: _openAddTodo,
            onOpenSearch: _openSearch,
            onOpenSettings: _openSettings,
            onMoveCategoryInto: (dragged, gid, siblings, at) => ref
                .read(categoriesControllerProvider)
                .moveCategoryInto(dragged, gid, siblings, at),
            onReorderGroups: (list, o, n) =>
                ref.read(groupsControllerProvider).reorder(list, o, n),
          ),
          const VerticalDivider(width: AppTokens.hairline),
          Expanded(
            child: InspectorScope(
              controller: _inspector,
              // 넓은 창에서 목록이 한없이 늘어나 눈이 좌우로 멀리 오가지 않게 최대 폭.
              // 캘린더는 폭이 곧 정보량이라 제외.
              child: location.page == ShellPage.calendar
                  ? mainContent
                  : _ReadableWidth(child: mainContent),
            ),
          ),
          if (_inspector.isOpen) ...[
            const VerticalDivider(width: AppTokens.hairline),
            SizedBox(
              width: InspectorPanel.widthFor(MediaQuery.sizeOf(context).width),
              child: InspectorPanel(controller: _inspector),
            ),
          ],
        ],
      );
    } else {
      body = SafeArea(child: mainContent);
    }

    final title = switch (location.page) {
      ShellPage.categories => '카테고리',
      _ => destination?.label ?? '오늘',
    };

    final shell = _ShortcutsHost(
      destinations: _destinations,
      onSelect: _selectByDigit,
      onOpenSearch: _openSearch,
      onAddTodo: _openAddTodo,
      onOpenSettings: _openSettings,
      onCloseInspector: () {
        if (!_inspector.isOpen) return false;
        _inspector.close();
        return true;
      },
      isInspectorOpen: () => _inspector.isOpen,
      // 모바일 시스템 뒤로가기 계단식 처리 — 카테고리→목록 / 그 밖→오늘.
      // canPop=false 로 두면 predictive-back 제스처도 앱 종료 대신 우리 핸들러로 라우팅된다.
      child: PopScope(
        canPop: !_mobileHasBackTarget(location),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleMobileBack();
        },
        child: Scaffold(
          // 모바일만 상단 앱바. 데스크탑은 좌측 _Sidebar 가 네비를 담당하므로 앱바 없음.
          //
          // 캘린더 화면도 앱바를 안 쓴다 — 달력은 세로 높이가 곧 정보량이라
          // "캘린더" 제목 한 줄에 56dp 를 내주면 주 행이 눈에 띄게 눌린다.
          // 검색·설정은 캘린더 헤더의 ⋮ 메뉴가 그대로 맡는다.
          appBar: AppPlatform.isDesktop || location.page == ShellPage.calendar
              ? null
              : AppBar(
                  title: Text(title),
                  // 카테고리 화면은 목록(4번째 칸)의 하위 화면 — 앱바 ← 로도 돌아간다.
                  leading: location.page == ShellPage.category
                      ? IconButton(
                          key: const ValueKey('category-back-button'),
                          icon: const Icon(Icons.arrow_back),
                          tooltip: _nav.returnTo == ShellLocation.outline
                              ? '전체보기'
                              : '카테고리 목록',
                          onPressed: () => _go(_categoryParent),
                        )
                      : null,
                  automaticallyImplyLeading: false,
                  actions: [
                    IconButton(
                      key: const ValueKey('search-button'),
                      icon: const Icon(Icons.search),
                      tooltip: '검색',
                      onPressed: _openSearch,
                    ),
                    IconButton(
                      key: const ValueKey('settings-button'),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: '설정',
                      onPressed: _openSettings,
                    ),
                  ],
                ),
          // 카테고리 목록 화면은 할 일이 아니라 카테고리를 다루는 곳이라 FAB 을 숨긴다
          // (하단의 '카테고리 추가 · 그룹 추가' 와 헷갈리지 않게).
          floatingActionButton: location.page == ShellPage.categories
              ? null
              : fab,
          // endFloat — Scaffold 가 FAB 를 bottomNavigationBar **위로** 띄워 네비를 가리지 않음.
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: body,
          // desktop 은 좌측 _Sidebar 가 네비게이션을 담당해 bottomNavigationBar 가 의도적으로
          // null. mobile 만 NavigationBar 노출 — 4칸 고정.
          bottomNavigationBar: AppPlatform.isDesktop
              ? null
              : _buildMobileNavBar(location, destination),
        ),
      ),
    );
    if (!AppPlatform.useNativeMenuBar) return shell;
    return PlatformMenuBar(menus: _menus(), child: shell);
  }

  /// macOS 메뉴바 — 단축키를 메뉴에서 찾을 수 있게(발견성). 동작은 앱 안 단축키와 같다.
  List<PlatformMenuItem> _menus() {
    PlatformMenuItem item(
      String label,
      VoidCallback onSelected, [
      MenuSerializableShortcut? shortcut,
    ]) => PlatformMenuItem(
      label: label,
      onSelected: onSelected,
      shortcut: shortcut,
    );
    final views = <PlatformMenuItem>[
      for (final d in _destinations)
        if (d.shortcutDigit >= 0 && d.shortcutDigit <= 9)
          item(
            d.label,
            () => _selectByDigit(d.shortcutDigit),
            SingleActivator(
              _ShortcutsHost._digitKeys[d.shortcutDigit]!,
              meta: true,
            ),
          ),
    ];
    return [
      PlatformMenu(
        label: '하루',
        menus: [
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.about,
          ),
          PlatformMenuItemGroup(
            members: [
              item(
                '설정…',
                _openSettings,
                const SingleActivator(LogicalKeyboardKey.comma, meta: true),
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: [
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.hideOtherApplications,
              ),
            ],
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.quit,
          ),
        ],
      ),
      PlatformMenu(
        label: '파일',
        menus: [
          item(
            '새 할 일',
            _openAddTodo,
            const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
          ),
          item(
            '검색',
            _openSearch,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
          ),
        ],
      ),
      PlatformMenu(
        label: '편집',
        menus: [
          // ⌘Z 는 입력 중이면 글자 되돌리기가 먼저 받는다(앱 안 단축키가 양보).
          item('되돌리기', runLatestUndo),
        ],
      ),
      PlatformMenu(
        label: '보기',
        menus: [
          PlatformMenuItemGroup(members: views),
          PlatformMenuItemGroup(members: [item('상세 패널 닫기', _inspector.close)]),
        ],
      ),
      const PlatformMenu(
        label: '윈도우',
        menus: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.minimizeWindow,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.zoomWindow,
          ),
        ],
      ),
    ];
  }
}

class _SelectDestinationIntent extends Intent {
  const _SelectDestinationIntent(this.digit);

  /// 0~9 단축키 digit. [AppDestination.shortcutDigit] 과 매핑.
  final int digit;
}

class _OpenSearchIntent extends Intent {
  const _OpenSearchIntent();
}

class _NewTodoIntent extends Intent {
  const _NewTodoIntent();
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _CloseInspectorIntent extends Intent {
  const _CloseInspectorIntent();
}

/// 앱 안 단축키 (macOS 관례, UX 개선 Phase 3).
///
/// - `0~9` / `⌘0~9` — destination (0 오늘 · 1 전체보기 · 2 캘린더 · 3~9 카테고리).
///   숫자만 누르는 것은 입력 중엔 꺼진다. ⌘ 조합은 입력 중에도 동작.
/// - `⌘N` 새 할 일 · `⌘F`/`⌘K` 검색 · `⌘,` 설정
/// - `⌘Z` — 화면에 떠 있는 되돌리기(스낵바)를 실행. 입력 중이면 글자 되돌리기에 양보.
/// - `Esc` — 오른쪽 인스펙터 닫기 (입력 중이 아닐 때).
class _ShortcutsHost extends StatelessWidget {
  const _ShortcutsHost({
    required this.destinations,
    required this.onSelect,
    required this.onOpenSearch,
    required this.onAddTodo,
    required this.onOpenSettings,
    required this.onCloseInspector,
    required this.isInspectorOpen,
    required this.child,
  });

  final List<AppDestination> destinations;
  final void Function(int digit) onSelect;
  final VoidCallback onOpenSearch;

  /// ⌘N — 앱 안 새 할 일. (전역은 ⌘⇧N, hotkey_manager 가 담당)
  final VoidCallback onAddTodo;
  final VoidCallback onOpenSettings;

  /// Esc — 인스펙터가 열려 있으면 닫고 true.
  final bool Function() onCloseInspector;
  final bool Function() isInspectorOpen;
  final Widget child;

  static const _digitKeys = <int, LogicalKeyboardKey>{
    0: LogicalKeyboardKey.digit0,
    1: LogicalKeyboardKey.digit1,
    2: LogicalKeyboardKey.digit2,
    3: LogicalKeyboardKey.digit3,
    4: LogicalKeyboardKey.digit4,
    5: LogicalKeyboardKey.digit5,
    6: LogicalKeyboardKey.digit6,
    7: LogicalKeyboardKey.digit7,
    8: LogicalKeyboardKey.digit8,
    9: LogicalKeyboardKey.digit9,
  };

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{};
    for (final d in destinations) {
      final digit = d.shortcutDigit;
      if (digit < 0) continue;
      final key = _digitKeys[digit];
      if (key == null) continue;
      shortcuts[SingleActivator(key)] = _SelectDestinationIntent(digit);
      shortcuts[SingleActivator(key, meta: true)] = _SelectDestinationIntent(
        digit,
      );
    }
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyF, meta: true)] =
        const _OpenSearchIntent();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyK, meta: true)] =
        const _OpenSearchIntent();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyN, meta: true)] =
        const _NewTodoIntent();
    shortcuts[const SingleActivator(LogicalKeyboardKey.comma, meta: true)] =
        const _OpenSettingsIntent();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyZ, meta: true)] =
        const _UndoIntent();
    shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] =
        const _CloseInspectorIntent();

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SelectDestinationIntent: _SelectDestinationAction(
            onSelect: onSelect,
          ),
          _OpenSearchIntent: CallbackAction<_OpenSearchIntent>(
            onInvoke: (_) {
              onOpenSearch();
              return null;
            },
          ),
          _NewTodoIntent: CallbackAction<_NewTodoIntent>(
            onInvoke: (_) {
              onAddTodo();
              return null;
            },
          ),
          _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
            onInvoke: (_) {
              onOpenSettings();
              return null;
            },
          ),
          _UndoIntent: _NotWhileTypingAction<_UndoIntent>(
            (_) => runLatestUndo(),
            when: hasLatestUndo,
          ),
          _CloseInspectorIntent: _NotWhileTypingAction<_CloseInspectorIntent>(
            (_) => onCloseInspector(),
            when: isInspectorOpen,
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

/// 숫자 단축키 Action. **입력 중엔 숫자만 누른 것은 꺼진다**(제목에 숫자 입력).
/// ⌘ 조합은 오타로 눌릴 일이 없어 입력 중에도 동작한다.
class _SelectDestinationAction extends Action<_SelectDestinationIntent> {
  _SelectDestinationAction({required this.onSelect});

  final void Function(int digit) onSelect;

  @override
  bool isEnabled(_SelectDestinationIntent intent) {
    if (!isFocusInEditableText()) return true;
    return HardwareKeyboard.instance.isMetaPressed;
  }

  @override
  Object? invoke(_SelectDestinationIntent intent) {
    onSelect(intent.digit);
    return null;
  }
}

/// 입력 중이면 꺼지는 Action — 키가 입력칸(글자 되돌리기·Esc)으로 그대로 간다.
/// [run] 이 false 를 돌려주면 처리하지 않은 것으로 보고 키를 흘려보낸다.
class _NotWhileTypingAction<T extends Intent> extends Action<T> {
  _NotWhileTypingAction(this.run, {this.when});

  final bool Function(T intent) run;

  /// 추가 조건 — false 면 꺼져서 키가 다른 곳으로 간다.
  final bool Function()? when;

  @override
  bool isEnabled(T intent) =>
      !isFocusInEditableText() && (when?.call() ?? true);

  @override
  bool consumesKey(T intent) => true;

  @override
  Object? invoke(T intent) => run(intent);
}

/// primaryFocus 가 [EditableText] (TextField 의 내부) 안에 있는지. 위 Action 의 isEnabled 가
/// 사용. visibleForTesting — 단위 검증 가능.
@visibleForTesting
bool isFocusInEditableText() {
  final focused = FocusManager.instance.primaryFocus;
  final ctx = focused?.context;
  if (ctx == null) return false;
  // EditableText 자기 자신이거나 그 안쪽 (Selection/Toolbar) 일 경우 모두 포착.
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// v1.3 — 데스크탑 사이드바. 오늘·전체보기·캘린더 → 미분류 → 그룹(접힘 가능) 순.
///
/// 메뉴·다이얼로그는 [CategoryActions] (모바일 카테고리 목록과 공용).
/// 그룹 머리 탭 = 전체보기 + 그 그룹 필터, chevron = 펼치기/접기(여러 그룹 동시, 저장).
class _Sidebar extends ConsumerStatefulWidget {
  const _Sidebar({
    required this.destinations,
    required this.groups,
    required this.selectedIndex,
    required this.selectedGroupId,
    required this.onSelect,
    required this.onSelectGroup,
    required this.onAddTodo,
    required this.onOpenSearch,
    required this.onOpenSettings,
    required this.onMoveCategoryInto,
    required this.onReorderGroups,
  });

  final List<AppDestination> destinations;
  final List<Group> groups;

  /// 선택된 destination index (없으면 -1).
  final int selectedIndex;

  /// 오늘·전체보기에서 켜진 그룹 필터 — 그 그룹 머리를 강조한다.
  final String? selectedGroupId;
  final ValueChanged<int> onSelect;

  /// 그룹 머리 탭 → 전체보기 + 그 그룹 필터.
  final ValueChanged<String> onSelectGroup;

  /// 사이드바 위 "새 할 일" — 데스크탑의 추가 진입점(⌘N 과 같음).
  final VoidCallback onAddTodo;

  /// 검색·설정 — ⌘K·⌘, 와 같은 경로(중복 열림 방지·인스펙터 연결 포함).
  final VoidCallback onOpenSearch;
  final VoidCallback onOpenSettings;

  /// 드래그→드롭(⠿/본문)을 다른 카테고리 행 위로 — [dragged] 를 [targetGroupId] 그룹의
  /// [orderedSiblings] 중 [insertIndex] 위치로 이동/순서변경.
  final void Function(
    Category dragged,
    String? targetGroupId,
    List<Category> orderedSiblings,
    int insertIndex,
  )
  onMoveCategoryInto;

  /// 그룹 헤더의 드래그 핸들(⠿)로 그룹 순서 변경 — groups 전체 + (oldIndex,newIndex).
  final void Function(List<Group> groups, int oldIndex, int newIndex)
  onReorderGroups;

  /// 접힌 그룹 id 집합의 저장 키.
  static const collapsedKey = 'sidebar.collapsedGroups';

  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  /// 드래그 중인 카테고리가 hover 중인 drop target. group id(String) 또는
  /// 미분류 센티넬 [_ungroupedTargetKey]. 시각 피드백용.
  Object? _hoverTarget;

  /// '미분류' drop target 의 hover 키 (groupId == null 과 구분).
  static const Object _ungroupedTargetKey = Object();

  PersistedIdSet get _collapsed =>
      ref.read(persistedIdSetProvider(_Sidebar.collapsedKey).notifier);

  CategoryActions get _actions => CategoryActions.of(context);

  /// 그룹 순서 변경 (그룹 헤더의 드래그 핸들 ⠿). groups 전체를 재배열해 sortOrder 갱신.
  /// 백엔드(GroupsController.reorder)가 (oldIndex,newIndex) 규약을 그대로 처리한다.
  void _reorderGroups(int oldIndex, int newIndex) {
    widget.onReorderGroups(widget.groups, oldIndex, newIndex);
  }

  /// 그룹 한 섹션(헤더 + 펼침 시 카테고리 리스트)을 [ReorderableListView] 아이템으로
  /// 구성. key 는 섹션이 들고, [reorderIndex] 로 헤더의 드래그 핸들을 연결한다.
  Widget _buildGroupSection(
    int reorderIndex,
    Group g,
    Map<String, List<int>> byGroup,
  ) {
    final cats = byGroup[g.id] ?? const <int>[];
    final expanded = !ref
        .watch(persistedIdSetProvider(_Sidebar.collapsedKey))
        .contains(g.id);
    return Column(
      key: ValueKey('sidebar-group-${g.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _GroupHeader(
          group: g,
          reorderIndex: reorderIndex,
          collapsed: !expanded,
          selected: widget.selectedGroupId == g.id,
          // 본문 탭 — 전체보기 + 이 그룹 필터 (접혀 있으면 펼친다).
          onSelect: () {
            _collapsed.set(g.id, false);
            widget.onSelectGroup(g.id);
          },
          onToggleCollapse: () => _collapsed.toggle(g.id),
          hovering: _hoverTarget == g.id,
          onMenu: (position) => _actions.showGroupMenu(
            g,
            position: position,
            onOpen: () => widget.onSelectGroup(g.id),
          ),
          onWillAccept: () => setState(() => _hoverTarget = g.id),
          onLeave: () => setState(() => _hoverTarget = null),
          onAccept: (cat) {
            setState(() => _hoverTarget = null);
            _actions.moveCategoryToGroup(cat, g.id);
          },
        ),
        // 그룹 안 카테고리는 들여써서 소속이 눈에 보이게.
        if (expanded && cats.isNotEmpty) _categorySection(cats, indent: true),
      ],
    );
  }

  /// destination index → SidebarItem 위젯. 카테고리만 삭제/이동 컨텍스트 메뉴 + 드래그.
  Widget _item(int index, {Key? key, bool indent = false}) {
    final dest = widget.destinations[index];
    final isCategory = dest.kind == DestinationKind.category;
    return SidebarItem(
      key: key,
      destination: dest,
      indent: indent,
      // "오늘" 옆 남은 할 일 수 — 사이드바만 봐도 오늘 얼마 남았는지.
      badge: dest.isToday ? ref.watch(undoneTodayCountProvider) : 0,
      selected: index == widget.selectedIndex,
      onTap: () => widget.onSelect(index),
      // 카테고리만 우클릭 → 커서 위치 메뉴 (수정 · 그룹 이동 · 보관 · 삭제).
      onContextMenu: isCategory
          ? (position) =>
                _actions.showCategoryMenu(dest.category!, position: position)
          : null,
      // 카테고리만 본문 길게누름 / ⠿ 로 드래그 이동·순서변경 가능 (E/K 통합).
      dragData: isCategory ? dest.category : null,
    );
  }

  /// 같은 그룹/미분류 섹션 — 각 행을 DragTarget 으로 감싸, 다른 카테고리를 그 행 위로
  /// 드롭하면 그 위치(앞)로 이동/순서변경(K, E 통합). 드래그 소스는 행 본문 길게누름
  /// 또는 ⠿ 핸들(SidebarItem 내부). 그룹 이동은 그룹 헤더/미분류 DragTarget 이 처리.
  Widget _categorySection(List<int> indices, {bool indent = false}) {
    final siblings = [
      for (final i in indices) widget.destinations[i].category!,
    ];
    return Column(
      children: [
        for (var i = 0; i < indices.length; i++)
          _CategoryDropRow(
            key: ValueKey('sidebar-cat-${siblings[i].id}'),
            target: siblings[i],
            sectionSiblings: siblings,
            onMoveInto: widget.onMoveCategoryInto,
            child: _item(indices[i], indent: indent),
          ),
      ],
    );
  }

  /// 미분류 섹션 — DragTarget(드롭하면 그룹에서 빼 미분류로) + 라벨 + 그 안의 카테고리.
  /// 그룹이 하나라도 있을 때만 노출 (그룹이 없으면 분류 개념 자체가 없음).
  Widget _ungroupedSection(List<int> ungrouped, TextTheme textTheme) {
    final scheme = Theme.of(context).colorScheme;
    final hovering = _hoverTarget == _ungroupedTargetKey;
    return DragTarget<Category>(
      onWillAcceptWithDetails: (details) {
        setState(() => _hoverTarget = _ungroupedTargetKey);
        return details.data.groupId != null;
      },
      onLeave: (_) => setState(() => _hoverTarget = null),
      onAcceptWithDetails: (details) {
        setState(() => _hoverTarget = null);
        _actions.moveCategoryToGroup(details.data, null);
      },
      builder: (context, candidate, rejected) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: AppTokens.space4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
            color: hovering
                ? scheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            border: hovering
                ? Border.all(color: scheme.primary, width: 1.4)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionLabel(label: '미분류', textTheme: textTheme),
              if (ungrouped.isNotEmpty)
                _categorySection(ungrouped)
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space20,
                    AppTokens.space2,
                    AppTokens.space20,
                    AppTokens.space8,
                  ),
                  child: Text(
                    '여기로 끌어 놓으면 그룹에서 빠져요',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final archivedCount =
        (ref.watch(archivedCategoriesProvider).asData?.value.length ?? 0) +
        (ref.watch(archivedGroupsProvider).asData?.value.length ?? 0);

    // 카테고리 destination 들을 groupId 별로 분류 (index 보존).
    final ungrouped = <int>[];
    final byGroup = <String, List<int>>{};
    int? outlineIndex;
    int? todayIndex;
    int? calendarIndex;
    for (var i = 0; i < widget.destinations.length; i++) {
      final d = widget.destinations[i];
      switch (d.kind) {
        case DestinationKind.today:
          todayIndex = i;
          break;
        case DestinationKind.outline:
          outlineIndex = i;
          break;
        case DestinationKind.calendar:
          calendarIndex = i;
          break;
        case DestinationKind.category:
          final gid = d.category?.groupId;
          if (gid == null) {
            ungrouped.add(i);
          } else {
            byGroup.putIfAbsent(gid, () => <int>[]).add(i);
          }
          break;
      }
    }

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space20,
          AppTokens.space8,
          AppTokens.space8,
          AppTokens.space16,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '하루',
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('search-button'),
              icon: const Icon(Icons.search, size: 20),
              tooltip: '검색 (⌘F · ⌘K)',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onOpenSearch,
            ),
            IconButton(
              key: const ValueKey('settings-button'),
              icon: const Icon(Icons.settings_outlined, size: 20),
              tooltip: '설정 (⌘,)',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onOpenSettings,
            ),
          ],
        ),
      ),
      // 새 할 일 — 항상 같은 자리(떠 있는 버튼은 인스펙터를 가려서 뺐다).
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space12,
          0,
          AppTokens.space12,
          AppTokens.space12,
        ),
        child: Tooltip(
          message: '새 할 일 (⌘N · 다른 앱에서 ⌘⇧N)',
          child: FilledButton.tonal(
            key: const ValueKey('sidebar-new-todo'),
            onPressed: widget.onAddTodo,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.add, size: 18),
                const SizedBox(width: AppTokens.space8),
                const Expanded(child: Text('새 할 일')),
                Text(
                  '⌘N',
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (todayIndex != null) _item(todayIndex),
      // v1.4 (Task G) — 전체보기를 '오늘' 바로 다음으로 (카테고리/그룹 섹션 앞).
      if (outlineIndex != null) _item(outlineIndex),
      // v1.6 — 캘린더 (월 달력 + 선택일 목록). 전체보기 다음, v1.5 타임라인 자리.
      if (calendarIndex != null) _item(calendarIndex),
      // 그룹별 섹션 — 헤더의 드래그 핸들(⠿)로 그룹 순서 변경(ReorderableListView).
      // 바깥 ListView 안에 들어가므로 shrinkWrap + NeverScrollable. 각 섹션은
      // 헤더(탭=그룹 화면 진입, chevron=접힘 토글, 드롭 타겟) + 펼침 시 카테고리.
      if (widget.groups.isNotEmpty)
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (oldI, newI) => _reorderGroups(oldI, newI),
          proxyDecorator: (child, index, animation) =>
              Material(color: Colors.transparent, child: child),
          children: [
            for (var i = 0; i < widget.groups.length; i++)
              _buildGroupSection(i, widget.groups[i], byGroup),
          ],
        ),
      // 미분류 — 그룹들 **아래** (전체보기·카테고리 목록과 같은 순서, Phase 2).
      // 그룹이 있으면 DragTarget(그룹 빼기)+라벨, 없으면 평면 리스트.
      if (widget.groups.isEmpty) ...[
        if (ungrouped.isNotEmpty) _categorySection(ungrouped),
      ] else
        _ungroupedSection(ungrouped, textTheme),
      // 카테고리/그룹 추가 — 목록 바로 아래 (FAB/Cmd+N 은 새 할 일 전용, Phase 0).
      const SizedBox(height: AppTokens.space8),
      const AddEntityButtons(),
      // 보관함 — 숨긴 그룹·카테고리가 있을 때만 (설정 안에 묻혀 있던 입구).
      if (archivedCount > 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.space8),
          child: TextButton.icon(
            key: const ValueKey('sidebar-archive'),
            style: TextButton.styleFrom(
              foregroundColor: colorScheme.onSurface.withValues(alpha: 0.72),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
                vertical: AppTokens.space8,
              ),
            ),
            onPressed: () => ArchiveScreen.show(context),
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: Text('보관함 ($archivedCount)'),
          ),
        ),
      const SizedBox(height: AppTokens.space12),
    ];

    return SizedBox(
      width: 220,
      child: ColoredBox(
        color: colorScheme.surfaceContainerHighest,
        child: SafeArea(
          right: false,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.space12),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// '미분류' 등 섹션 라벨 (그룹 헤더보다 약한 시각 강조).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.textTheme});

  final String label;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space20,
        AppTokens.space12,
        AppTokens.space20,
        AppTokens.space4,
      ),
      child: Text(
        label,
        style: textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 그룹 헤더 — 색 dot + label + 접힘 chevron.
///
/// 본문 탭 = 그 그룹 화면 진입(onSelect), 우측 chevron = 접힘 토글(onToggleCollapse).
/// 선택된 그룹은 배경 강조. long-press/우클릭 = 그룹 메뉴(수정/삭제).
/// [onAccept] 가 주어지면 카테고리 드래그의 DragTarget — 드롭하면 그 그룹으로 이동.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.reorderIndex,
    required this.collapsed,
    required this.selected,
    required this.onSelect,
    required this.onToggleCollapse,
    this.onMenu,
    this.hovering = false,
    this.onWillAccept,
    this.onLeave,
    this.onAccept,
  });

  final Group group;

  /// 그룹 [ReorderableListView] 안에서의 인덱스 — 드래그 핸들(⠿)이 사용.
  final int reorderIndex;
  final bool collapsed;
  final bool selected;

  /// 본문 탭 — 그룹 화면 진입.
  final VoidCallback onSelect;

  /// chevron 탭 — 접힘 토글.
  final VoidCallback onToggleCollapse;

  /// long-press(위치 null → 시트) / 우클릭(커서 위치 → 팝업) — 그룹 메뉴.
  final void Function(Offset? position)? onMenu;

  /// 카테고리 드래그가 이 헤더 위에 hover 중인지 — 색/테두리 피드백.
  final bool hovering;
  final VoidCallback? onWillAccept;
  final VoidCallback? onLeave;

  /// non-null 이면 DragTarget 활성 — 드롭된 카테고리를 이 그룹으로 이동.
  final ValueChanged<Category>? onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 선택 = primary 배경, (선택 아닐 때) 드래그 hover = 그룹색 배경.
    final bg = selected
        ? scheme.primary.withValues(alpha: 0.12)
        : (hovering ? group.color.withValues(alpha: 0.18) : Colors.transparent);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space8,
        AppTokens.space8,
        AppTokens.space8,
        AppTokens.space2,
      ),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          onTap: onSelect,
          onLongPress: onMenu == null ? null : () => onMenu!(null),
          onSecondaryTapUp: onMenu == null
              ? null
              : (d) => onMenu!(d.globalPosition),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTokens.radiusM),
              border: hovering
                  ? Border.all(color: group.color, width: 1.6)
                  : null,
            ),
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space12,
              AppTokens.space4,
              AppTokens.space4,
              AppTokens.space4,
            ),
            child: Row(
              children: [
                Icon(Icons.circle, size: 12, color: group.color),
                const SizedBox(width: AppTokens.space8),
                Expanded(
                  child: Text(
                    group.label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface.withValues(
                        alpha: selected ? 1.0 : 0.85,
                      ),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 18,
                  ),
                  color: scheme.onSurface.withValues(alpha: 0.5),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  tooltip: collapsed ? '펼치기' : '접기',
                  onPressed: onToggleCollapse,
                ),
                // 드래그 핸들 — 그룹 순서 변경. 헤더 본문 탭/롱프레스/드롭타겟과
                // 별개 제스처라 충돌하지 않는다.
                ReorderableDragStartListener(
                  index: reorderIndex,
                  child: Padding(
                    padding: const EdgeInsets.only(right: AppTokens.space4),
                    child: Icon(
                      Icons.drag_indicator,
                      size: 18,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (onAccept == null) return header;
    return DragTarget<Category>(
      onWillAcceptWithDetails: (details) {
        onWillAccept?.call();
        // 이미 이 그룹이면 시각상 거절 (drop 은 어차피 no-op 가드).
        return details.data.groupId != group.id;
      },
      onLeave: (_) => onLeave?.call(),
      onAcceptWithDetails: (details) => onAccept!(details.data),
      builder: (context, candidate, rejected) => header,
    );
  }
}

/// 사이드바 카테고리 행 — DragTarget. 다른 카테고리를 이 행 위로 드롭하면 이 행의
/// 그룹·바로 앞 위치로 이동/순서변경(K, E 통합). 드래그 소스는 자식([SidebarItem])의
/// 본문 길게누름 / ⠿ 핸들. hover 시 윗변에 삽입선 표시.
class _CategoryDropRow extends StatefulWidget {
  const _CategoryDropRow({
    super.key,
    required this.target,
    required this.sectionSiblings,
    required this.onMoveInto,
    required this.child,
  });

  /// 이 행의 카테고리 (드롭 시 삽입 기준 위치).
  final Category target;

  /// 이 행이 속한 섹션(그룹/미분류)의 카테고리들 — 화면 순서.
  final List<Category> sectionSiblings;

  final void Function(
    Category dragged,
    String? targetGroupId,
    List<Category> orderedSiblings,
    int insertIndex,
  )
  onMoveInto;

  final Widget child;

  @override
  State<_CategoryDropRow> createState() => _CategoryDropRowState();
}

class _CategoryDropRowState extends State<_CategoryDropRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<Category>(
      onWillAcceptWithDetails: (details) {
        final ok = details.data.id != widget.target.id;
        if (ok && !_hovering) setState(() => _hovering = true);
        return ok;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        final dragged = details.data;
        final siblings = widget.sectionSiblings
            .where((c) => c.id != dragged.id)
            .toList();
        var insertAt = siblings.indexWhere((c) => c.id == widget.target.id);
        if (insertAt < 0) insertAt = siblings.length;
        widget.onMoveInto(dragged, widget.target.groupId, siblings, insertAt);
      },
      builder: (context, candidate, rejected) {
        return Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: _hovering ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: widget.child,
        );
      },
    );
  }
}

class SidebarItem extends StatefulWidget {
  @visibleForTesting
  const SidebarItem({
    super.key,
    required this.destination,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.onContextMenu,
    this.autofocus = false,
    this.dragData,
    this.indent = false,
    this.badge = 0,
  });

  final AppDestination destination;
  final bool selected;
  final VoidCallback onTap;

  /// 우클릭 / (드래그 불가 시) long-press — 카테고리 컨텍스트 메뉴 진입점. null 이면 비활성.
  final VoidCallback? onLongPress;

  /// 우클릭 — 커서 위치(global)를 받아 그 자리에 메뉴. 있으면 [onLongPress] 대신 쓴다.
  final void Function(Offset globalPosition)? onContextMenu;

  /// 그룹 안 카테고리 — 12px 들여쓰기.
  final bool indent;

  /// 오른쪽 숫자 배지(0 이면 없음) — "오늘" 의 남은 할 일 수.
  final int badge;

  /// 테스트 결정성 — true 면 mount 직후 InkWell 이 focus 를 잡는다.
  final bool autofocus;

  /// non-null(=카테고리) 이면 두 가지 드래그 소스를 단다: 본문 길게누름 + 우측 ⠿ 핸들.
  /// 둘 다 [Category] 를 실어 그룹 헤더/미분류(이동)·다른 행(순서변경) DragTarget 으로 드롭.
  /// long-press 가 드래그에 쓰이므로 set 되면 long-press 메뉴는 끄고 우클릭으로만 연다.
  final Category? dragData;

  @override
  State<SidebarItem> createState() => SidebarItemState();
}

class SidebarItemState extends State<SidebarItem> {
  /// 키보드 focus 가 이 item 에 들어와 있는지. true 면 outline ring 표시 — 마우스 사용자
  /// 에게도 영향 X (InkWell.onFocusChange 는 키보드 traversal 에서만 true 가 됨).
  bool _focused = false;

  /// 마우스가 올라와 있는지 — ⠿ 는 이때만 보인다(평소엔 목록이 조용하게).
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = widget.selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.78);
    final bg = widget.selected
        ? scheme.primary.withValues(alpha: 0.12)
        : Colors.transparent;

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      side: _focused
          ? BorderSide(color: scheme.primary, width: 2)
          : BorderSide.none,
    );

    final draggable = widget.dragData != null;

    final tile = Padding(
      padding: EdgeInsets.only(
        left: AppTokens.space8 + (widget.indent ? AppTokens.space12 : 0),
        right: AppTokens.space8,
        top: AppTokens.space2,
        bottom: AppTokens.space2,
      ),
      child: Tooltip(
        message: widget.destination.tooltipWithShortcut,
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          color: bg,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            // 드래그 가능하면 long-press 는 드래그 전용 → 메뉴는 우클릭으로만.
            onLongPress: draggable ? null : widget.onLongPress,
            // 데스크탑의 우클릭은 항상 컨텍스트 메뉴 (수정 · 그룹 이동 · 보관 · 삭제).
            onSecondaryTap: widget.onContextMenu == null
                ? widget.onLongPress
                : null,
            onSecondaryTapUp: widget.onContextMenu == null
                ? null
                : (d) => widget.onContextMenu!(d.globalPosition),
            autofocus: widget.autofocus,
            // 키보드 focus 가 들어왔다 나갔다 할 때 outline ring 토글.
            onFocusChange: (f) => setState(() => _focused = f),
            // InkWell 의 기본 focusColor (semi-transparent) 는 따로 outline 을 그리므로 끔.
            focusColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
                vertical: AppTokens.space8,
              ),
              child: Row(
                children: [
                  Icon(
                    widget.destination.icon,
                    size: 18,
                    color: widget.destination.color,
                  ),
                  const SizedBox(width: AppTokens.space12),
                  Expanded(
                    child: Text(
                      widget.destination.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: fg,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.badge > 0)
                    Text(
                      '${widget.badge}',
                      key: const ValueKey('sidebar-badge'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  if (draggable)
                    AnimatedOpacity(
                      opacity: _hovered || _focused ? 1 : 0,
                      duration: AppTokens.motionFast,
                      child: Draggable<Category>(
                        // ⠿ 를 잡고 → 그룹 헤더/미분류에 놓으면 그룹 이동, 다른 행에 놓으면
                        // 순서변경(상위 DragTarget 들이 처리). 마우스로 바로 끌림(즉시 드래그).
                        data: widget.dragData!,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: _CategoryDragFeedback(
                          destination: widget.destination,
                        ),
                        childWhenDragging: Icon(
                          Icons.drag_indicator,
                          size: 16,
                          color: scheme.onSurface.withValues(alpha: 0.2),
                        ),
                        child: Icon(
                          Icons.drag_indicator,
                          size: 16,
                          color: scheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final hoverable = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: tile,
    );
    if (!draggable) return hoverable;
    // 길게 눌러 그룹 헤더/미분류로 드롭 → 그룹 이동(E). ⠿ 순서변경과 별개 제스처.
    return LongPressDraggable<Category>(
      data: widget.dragData!,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _CategoryDragFeedback(destination: widget.destination),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: hoverable,
    );
  }
}

/// 사이드바 카테고리 드래그 중 손가락/커서 아래 떠다니는 피드백 칩.
class _CategoryDragFeedback extends StatelessWidget {
  const _CategoryDragFeedback({required this.destination});

  final AppDestination destination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space12,
          vertical: AppTokens.space8,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          border: Border.all(color: destination.color, width: 1.6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(destination.icon, size: 16, color: destination.color),
            const SizedBox(width: AppTokens.space8),
            Text(
              destination.label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 데스크탑 본문 최대 폭 — 넓은 창에서 가운데 정렬.
class _ReadableWidth extends StatelessWidget {
  const _ReadableWidth({required this.child});

  final Widget child;

  static const double maxWidth = 960;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

class _MainArea extends StatelessWidget {
  const _MainArea({required this.destination});

  final AppDestination destination;

  @override
  Widget build(BuildContext context) {
    if (destination.isToday) return const HomeScreen();
    if (destination.isOutline) return const OutlineScreen();
    // v1.6 — 캘린더. 흡수된 타임라인 목록은 이 화면의 `[목록]` 세그먼트에 있다.
    if (destination.isCalendar) return const CalendarScreen();
    return CategoryView(category: destination.category!);
  }
}
