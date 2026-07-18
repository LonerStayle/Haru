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
import '../features/add_todo/add_todo_controller.dart';
import '../features/add_todo/add_todo_sheet.dart';
import '../features/auth/auth_providers.dart';
import '../features/category/add_category_dialog.dart';
import '../features/category/add_group_dialog.dart';
import '../features/category/categories_controller.dart';
import '../features/category/groups_controller.dart';
import '../features/category/category_view.dart';
import '../features/group/group_screen.dart';
import '../features/home/home_screen.dart';
import '../features/home/today_providers.dart';
import '../features/manage/manage_drawer.dart';
import '../features/outline/outline_screen.dart';
import '../features/settings/settings_sheet.dart';
import '../features/system/tray_service.dart';
import '../features/timeline/timeline_screen.dart';
import 'destination.dart';
import 'widgets/undo_snackbar.dart';

/// 폼팩터 분기 컨테이너 + FAB (빠른 추가 트리거) + 1~5 카테고리 단축키.
///
/// 단축키: `0` = Today, `1` = work, `2` = personalDev, `3` = daily, `4` = longterm, `5` = idea.
/// macOS 데스크탑 global Cmd+N 은 phase 6 의 hotkey_manager task 에서 연결.
///
/// **시스템 단축키 비충돌 점검** (macOS):
///   - 우리가 잡는 modifier+key 조합은 **Cmd+N (글로벌)** 뿐. Cmd+W (Close window) /
///     Cmd+Q (Quit) / Cmd+M (Minimize) / Cmd+H (Hide) / Cmd+, (Preferences) 등은
///     macOS 가 그대로 처리하도록 둠.
///   - 0~5 는 modifier 없는 plain digit — TextField focus 시 [isFocusInEditableText] 가드로
///     숫자 입력에 양보 (text 입력 가능).
///   - Esc 는 AddTodoSheet 의 _DismissIntent (sheet 닫기) — macOS 의 dialog 닫기와
///     관행 일치, 충돌 없음.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  /// A안 — 선택된 그룹 id. non-null 이면 main area 에 그룹 화면([GroupScreen],
  /// 오늘/전체보기 탭)을 띄운다. today/category/outline destination 을 고르면 null 로
  /// 리셋된다. 선택한 그룹이 삭제되면 build 단계에서 자동으로 null fallback.
  String? _selectedGroupId;

  HotKey? _cmdN;
  TrayService? _tray;

  /// 모바일 Drawer 를 NavigationBar '카테고리' 슬롯에서 열기 위한 키.
  /// (NavigationBar 는 Scaffold 의 형제라 Scaffold.of 로 접근 불가 → key 사용.)
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 모바일 Drawer 열림 여부 — 시스템 뒤로가기([PopScope]) 판정에 쓰인다.
  /// `Scaffold.onDrawerChanged` 로 갱신 → build 재실행 → [_mobileHasBackTarget] 재평가.
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    _registerGlobalHotkey();
    _initTray();
  }

  @override
  void dispose() {
    _unregisterGlobalHotkey();
    _tray?.dispose();
    super.dispose();
  }

  Future<void> _initTray() async {
    if (!AppPlatform.isDesktop) return;
    final tray = TrayService(
      onAddTodo: () {
        if (mounted) _openAddTodo();
      },
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
      final hotkey = HotKey(
        key: PhysicalKeyboardKey.keyN,
        modifiers: const [HotKeyModifier.meta],
        scope: HotKeyScope.system,
      );
      try {
        await hotKeyManager.unregister(hotkey);
      } catch (_) {
        // 등록 안 되어 있으면 무시 — register 만 진행.
      }
      await hotKeyManager.register(
        hotkey,
        keyDownHandler: (_) {
          if (mounted) _openAddMenu();
        },
      );
      _cmdN = hotkey;
    } catch (e) {
      // 글로벌 단축키 등록 실패 (test 환경 / 권한 거부) — FAB 으로 대체 가능하므로 fatal X.
      debugPrint('[solo_todo] Cmd+N 글로벌 단축키 등록 실패: $e');
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

  void _select(int i) {
    // destination 선택은 그룹 화면을 빠져나간다 (A안).
    setState(() {
      _index = i;
      _selectedGroupId = null;
    });
  }

  /// A안 — 사이드바/Drawer 에서 그룹 헤더 탭 → 그 그룹 화면(오늘/전체보기 탭) 진입.
  void _selectGroup(String groupId) {
    setState(() => _selectedGroupId = groupId);
  }

  /// 모바일 시스템 뒤로가기(백버튼/제스처)로 "가로챌 것" 이 있는지.
  ///
  /// true 면 [PopScope.canPop] = false 로 두어 OS 에 "이 back 은 내가 처리한다" 를 알리고
  /// (predictive-back 제스처도 앱 종료 대신 우리 핸들러로 라우팅됨), [_handleMobileBack]
  /// 이 계단식으로 소비한다. 계단 우선순위: Drawer 열림 > 그룹 화면 > 비-오늘 탭.
  ///
  /// 데스크탑은 시스템 뒤로가기가 없으므로 항상 false (PopScope 무력화).
  bool get _mobileHasBackTarget {
    if (!AppPlatform.isMobile) return false;
    if (_drawerOpen) return true;
    if (_selectedGroupId != null) return true;
    if (_destinations.isEmpty) return false;
    final safeIndex = _index < _destinations.length ? _index : 0;
    return !_destinations[safeIndex].isToday;
  }

  /// 모바일 시스템 뒤로가기 계단식 처리 — [_mobileHasBackTarget] 이 true 일 때만 호출된다.
  ///   1) Drawer 열림 → 닫기
  ///   2) 그룹 화면 진입 → 원래 탭으로 복귀
  ///   3) 비-오늘 탭 → '오늘' 탭으로 복귀
  /// (셋 다 아니면 canPop=true 라 여기 오지 않음 → 그때만 OS 가 앱을 종료.)
  void _handleMobileBack() {
    if (_drawerOpen) {
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }
    if (_selectedGroupId != null) {
      setState(() => _selectedGroupId = null);
      return;
    }
    final todayIndex = _destinations.indexWhere((d) => d.isToday);
    if (todayIndex >= 0 && _index != todayIndex) {
      _select(todayIndex);
    }
  }

  /// 모바일 Drawer 에서 그룹 탭 → 그룹 화면 진입 + Drawer 닫기.
  void _selectGroupFromDrawer(Group group) {
    _selectGroup(group.id);
    Navigator.of(context).pop();
  }

  /// 단축키 digit (0~9) → destination index 매핑. 0 Today, 1~min(9,N) 카테고리,
  /// N+1 (N<9 일 때) outline. 매칭 못 하면 no-op.
  void _selectByDigit(int digit) {
    final idx = _destinations.indexWhere((d) => d.shortcutDigit == digit);
    if (idx >= 0 && idx != _index) _select(idx);
  }

  /// 카테고리 삭제 — confirm dialog 후 controller 호출. blocked 면 안내 dialog.
  /// today / outline destination 은 무시.
  Future<void> _deleteCategory(AppDestination dest) async {
    final category = dest.category;
    if (category == null) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${category.label} 카테고리 삭제'),
            content: const Text('이 카테고리를 정말 삭제할까요? 되돌릴 수 없어요.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    final result = await ref
        .read(categoriesControllerProvider)
        .delete(category.id);
    if (!mounted) return;
    if (result.isOk) {
      // _index 가 삭제된 카테고리에 가 있었다면 다음 build 에서 safeIndex 가 today 로
      // fallback. _index 자체도 안전 reset.
      setState(() {
        if (_index >= _destinations.length - 1) _index = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${category.label} 카테고리가 삭제되었어요.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // blockedByTodos — 안 todos 가 있어 차단됨. 안내 dialog.
    final count = await ref
        .read(categoriesRepositoryProvider)
        .countTodosOfCategory(category.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('삭제할 수 없어요'),
        content: Text(
          '이 카테고리에 할 일이 $count건 있어요. 먼저 다른 카테고리로 옮기거나 todos 부터 삭제해 주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  /// 그룹 삭제 — confirm dialog 후 controller 호출. 차단 없음: 속한 카테고리는
  /// '미분류'로 이동되고 그룹만 사라진다 (todos / 카테고리 데이터 무손실).
  Future<void> _deleteGroup(Group group) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text("'${group.label}' 그룹 삭제"),
            content: const Text(
              '그룹을 삭제하면 속한 카테고리는 \'미분류\'로 이동돼요. 카테고리와 할 일은 그대로 남아요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    await ref.read(groupsControllerProvider).delete(group.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("'${group.label}' 그룹이 삭제됐어요. 카테고리는 미분류로 이동했어요."),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 데스크탑 사이드바 — 카테고리 보관 (할 일 포함 숨김). 되돌리기 스낵바.
  Future<void> _archiveCategory(AppDestination dest) async {
    final category = dest.category;
    if (category == null) return;
    await ref.read(categoriesControllerProvider).archive(category.id);
    if (!mounted) return;
    showUndoSnackbar(
      context,
      message: '${category.label} 카테고리를 보관했어요.',
      onUndo: () =>
          ref.read(categoriesControllerProvider).unarchive(category.id),
    );
  }

  /// 데스크탑 사이드바 — 그룹 보관 (소속 카테고리·할 일 cascade 숨김). 되돌리기 스낵바.
  Future<void> _archiveGroup(Group group) async {
    await ref.read(groupsControllerProvider).archive(group.id);
    if (!mounted) return;
    showUndoSnackbar(
      context,
      message: "'${group.label}' 그룹을 보관했어요. (카테고리·할 일 포함)",
      onUndo: () => ref.read(groupsControllerProvider).unarchive(group.id),
    );
  }

  /// 그룹 이름/색 수정 — 프리필된 다이얼로그(upsert). 같은 id 라 카테고리 소속 유지.
  Future<void> _editGroup(Group group) =>
      AddGroupDialog.showEdit(context, group);

  /// 드래그→드롭으로 카테고리를 그룹(또는 미분류=null)으로 직접 이동. (사이드바 E)
  Future<void> _dropCategoryToGroup(Category category, String? groupId) async {
    if (category.groupId == groupId) return;
    await ref
        .read(categoriesControllerProvider)
        .moveToGroup(category.id, groupId);
  }

  /// 카테고리 '그룹 이동' — 그룹 선택 bottom sheet 후 controller.moveToGroup 호출.
  /// 선택지: 미분류(null) + 현재 그룹들. today / outline 은 무시.
  Future<void> _moveCategoryToGroup(AppDestination dest) async {
    final category = dest.category;
    if (category == null) return;

    final groups =
        ref.read(activeGroupsProvider).asData?.value ?? const <Group>[];
    final picked = await showModalBottomSheet<_GroupChoice>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.layers_clear_outlined),
              title: const Text('미분류'),
              selected: category.groupId == null,
              onTap: () => Navigator.of(ctx).pop(const _GroupChoice(null)),
            ),
            for (final g in groups)
              ListTile(
                leading: Icon(Icons.circle, size: 14, color: g.color),
                title: Text(g.label),
                selected: category.groupId == g.id,
                onTap: () => Navigator.of(ctx).pop(_GroupChoice(g.id)),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await ref
        .read(categoriesControllerProvider)
        .moveToGroup(category.id, picked.groupId);
  }

  /// 그룹 순서 변경 (사이드바 그룹 헤더의 드래그 핸들 ⠿). groups 전체를 재배열해
  /// sortOrder 갱신 (GroupsController.reorder 가 바뀐 그룹만 upsert).
  Future<void> _reorderGroups(
    List<Group> groups,
    int oldIndex,
    int newIndex,
  ) async {
    await ref
        .read(groupsControllerProvider)
        .reorder(groups, oldIndex, newIndex);
  }

  /// 드래그→드롭(⠿/본문) 통합 — 카테고리를 대상 그룹의 특정 위치로 이동/순서변경.
  Future<void> _moveCategoryInto(
    Category dragged,
    String? targetGroupId,
    List<Category> orderedSiblings,
    int insertIndex,
  ) async {
    await ref
        .read(categoriesControllerProvider)
        .moveCategoryInto(dragged, targetGroupId, orderedSiblings, insertIndex);
  }

  /// FAB / Cmd+N 진입점 — 바로 새 할일을 띄우지 않고 **추가 선택 시트**를 먼저 연다.
  /// 새 할일 / 카테고리 / 그룹 중 하나를 고르는 단일 추가 동선 (대표님 요청).
  Future<void> _openAddMenu() async {
    final choice = await showModalBottomSheet<_AddAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddActionSheet(),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case _AddAction.todo:
        await _openAddTodo();
      case _AddAction.category:
        await AddCategoryDialog.show(context);
      case _AddAction.group:
        await AddGroupDialog.show(context);
    }
  }

  Future<void> _openAddTodo() async {
    // _index 가 destinations 범위를 벗어났을 수 있으므로 safe lookup.
    final dest = (_index < _destinations.length)
        ? _destinations[_index]
        : _destinations.first;
    // 카테고리 화면이면 그 카테고리. 오늘/전체보기/FAB/Cmd+N 전역 추가는 컨텍스트가
    // 없으므로 **현재 카테고리 목록의 첫 항목**(정렬 기준)을 기본값으로. 무조건 '일상'
    // 으로 떨어지던 버그 (J) 수정 — 목록이 비면 builtinSeeds.first 로 fallback.
    final categories =
        ref.read(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    final fallback = categories.isNotEmpty
        ? categories.first
        : Category.builtinSeeds.first;
    final initialCategory = dest.category ?? fallback;

    // sheet 가 닫힌 후 controller 를 호출해 결과(Calendar 경고 등)를 처리한다.
    AddTodoSubmission? submitted;
    await AddTodoSheet.show(
      context,
      initialCategory: initialCategory,
      onSubmit: (s) => submitted = s,
    );
    if (submitted == null || !mounted) return;

    final result = await ref.read(addTodoControllerProvider).add(submitted!);
    if (!mounted) return;
    final warning = result.calendarWarning;
    if (warning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(warning), behavior: SnackBarBehavior.floating),
      );
    }
  }

  /// Drawer 에서 카테고리 탭 → 그 카테고리 destination 으로 이동 + Drawer 닫기.
  /// destinations 에서 같은 category id 의 index 를 찾아 _select.
  void _selectCategoryDestination(Category category) {
    final idx = _destinations.indexWhere(
      (d) =>
          d.kind == DestinationKind.category && d.category?.id == category.id,
    );
    if (idx >= 0) _select(idx);
    Navigator.of(context).pop(); // drawer 닫기
  }

  /// 모바일 하단 바 (옵션 1) — `[오늘, 전체보기, 카테고리]` 3 슬롯 고정.
  ///
  /// selectedIndex 는 **가상 인덱스** (destinations 의 실제 index 와 분리):
  ///   - today → 0, outline → 1, 그 외(어느 카테고리든) → 2 (카테고리 슬롯).
  /// 탭:
  ///   - 0 → today destination 으로 _select
  ///   - 1 → outline destination 으로 _select
  ///   - 2 → 관리 Drawer 열기 (카테고리 선택은 Drawer 안에서)
  /// 카테고리 슬롯 라벨/아이콘은 현재 카테고리에 있으면 그 카테고리, 아니면 기본값.
  Widget _buildMobileNavBar(AppDestination current, Group? selectedGroup) {
    // 그룹 화면일 땐 '카테고리' 슬롯(관리 Drawer 진입점)을 선택 상태로 — 그룹은 그
    // Drawer 에서 고르므로 일관적이다. 슬롯 라벨/아이콘도 그룹명/폴더로 바꿔 표시.
    final groupActive = selectedGroup != null;
    final onCategory = current.kind == DestinationKind.category;
    // 슬롯: 0=오늘 1=전체보기 2=타임라인 3=카테고리(관리 Drawer 진입점).
    final navSelected = groupActive
        ? 3
        : current.isToday
        ? 0
        : current.isOutline
        ? 1
        : current.isTimeline
        ? 2
        : 3;

    final todayDest = _destinations.firstWhere((d) => d.isToday);
    final outlineDest = _destinations.firstWhere((d) => d.isOutline);
    final timelineDest = _destinations.firstWhere((d) => d.isTimeline);

    final categoryIcon = groupActive
        ? Icons.folder_outlined
        : onCategory
        ? current.icon
        : Icons.category_outlined;
    final categoryLabel = groupActive
        ? selectedGroup.label
        : onCategory
        ? current.label
        : '카테고리';

    return NavigationBar(
      selectedIndex: navSelected,
      onDestinationSelected: (i) {
        switch (i) {
          case 0:
            _selectByDestination(todayDest);
            break;
          case 1:
            _selectByDestination(outlineDest);
            break;
          case 2:
            _selectByDestination(timelineDest);
            break;
          case 3:
            _scaffoldKey.currentState?.openDrawer();
            break;
        }
      },
      destinations: [
        NavigationDestination(icon: Icon(todayDest.icon), label: '오늘'),
        NavigationDestination(icon: Icon(outlineDest.icon), label: '전체보기'),
        NavigationDestination(icon: Icon(timelineDest.icon), label: '타임라인'),
        NavigationDestination(icon: Icon(categoryIcon), label: categoryLabel),
      ],
    );
  }

  /// destination 객체 → 그 index 로 _select.
  void _selectByDestination(AppDestination dest) {
    final idx = _destinations.indexOf(dest);
    if (idx >= 0) _select(idx);
  }

  @override
  Widget build(BuildContext context) {
    // 미체크 카운트가 바뀌면 tray title 갱신 (macOS 만 실효).
    ref.listen<int>(undoneTodayCountProvider, (_, next) {
      _tray?.updateUndoneCount(next);
    });

    // Supabase realtime sync — 인증된 user 가 있을 때만 활성. lifecycle 은 provider 가 관리.
    ref.watch(supabaseRealtimeSyncProvider);

    // user 가 다른 계정으로 바뀌면 옛 todos/outbox 자동 정리 (side-effect listener).
    ref.watch(userChangeCleanupProvider);

    // v1.2 — 활성 카테고리 stream 에 따라 destinations 동적 build (보관 카테고리 제외).
    // loading / error 시 fallback 으로 builtin 5종 기준의 default 사용.
    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ??
        Category.builtinSeeds;
    _destinations = AppDestination.buildAll(categories);

    // v1.3 — 활성 그룹 stream. 사이드바가 그룹 헤더 + 미분류 섹션으로 카테고리를 묶는다.
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];

    // _index 가 destinations.length 초과 (카테고리 삭제 직후 등) 면 Today (0) 으로 안전 fallback.
    final safeIndex = _index < _destinations.length ? _index : 0;
    final destination = _destinations[safeIndex];

    // A안 — 선택된 그룹 resolve. 삭제됐으면 null (→ destination 화면으로 fallback).
    Group? selectedGroup;
    if (_selectedGroupId != null) {
      for (final g in groups) {
        if (g.id == _selectedGroupId) {
          selectedGroup = g;
          break;
        }
      }
    }

    // main area 에 띄울 화면 — 그룹 선택 시 그룹 화면, 아니면 destination 화면.
    final Widget mainContent = selectedGroup != null
        ? GroupScreen(
            key: ValueKey('group-${selectedGroup.id}'),
            group: selectedGroup,
          )
        : _MainArea(destination: destination);

    // 모바일은 NavigationBar 를 가리지 않도록 컴팩트한 원형 FAB (endFloat 가 바 위로 띄움).
    // 데스크탑은 nav bar 가 없어 넓은 extended FAB 유지.
    final fab = AppPlatform.isDesktop
        ? FloatingActionButton.extended(
            key: const ValueKey('add-todo-fab'),
            onPressed: _openAddMenu,
            icon: const Icon(Icons.add),
            label: const Text('추가'),
            tooltip: '추가 (Cmd+N)',
          )
        : FloatingActionButton(
            key: const ValueKey('add-todo-fab'),
            onPressed: _openAddMenu,
            tooltip: '추가',
            child: const Icon(Icons.add),
          );

    final Widget body;
    if (AppPlatform.isDesktop) {
      body = Row(
        children: [
          _Sidebar(
            destinations: _destinations,
            groups: groups,
            selectedIndex: safeIndex,
            selectedGroupId: selectedGroup?.id,
            onSelect: _select,
            onSelectGroup: _selectGroup,
            onDeleteCategory: _deleteCategory,
            onMoveCategory: _moveCategoryToGroup,
            onArchiveCategory: _archiveCategory,
            onDeleteGroup: _deleteGroup,
            onArchiveGroup: _archiveGroup,
            onEditGroup: _editGroup,
            onDropCategoryToGroup: _dropCategoryToGroup,
            onMoveCategoryInto: _moveCategoryInto,
            onReorderGroups: _reorderGroups,
          ),
          const VerticalDivider(width: AppTokens.hairline),
          Expanded(child: mainContent),
        ],
      );
    } else {
      body = SafeArea(child: mainContent);
    }

    return _ShortcutsHost(
      destinations: _destinations,
      onSelect: _selectByDigit,
      // 모바일 시스템 뒤로가기 계단식 처리 — Drawer 닫기 / 그룹 나가기 / 오늘 복귀.
      // canPop=false 로 두면 predictive-back 제스처도 앱 종료 대신 우리 핸들러로 라우팅된다.
      child: PopScope(
        canPop: !_mobileHasBackTarget,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleMobileBack();
        },
        child: Scaffold(
          key: _scaffoldKey,
          // Drawer 열림/닫힘 → canPop 재평가를 위해 상태 반영.
          onDrawerChanged: (isOpen) {
            if (_drawerOpen != isOpen) setState(() => _drawerOpen = isOpen);
          },
          // 모바일만 상단 앱바 — ☰ 로 그룹/카테고리 관리 Drawer 를 연다 (Task A).
          // 데스크탑은 좌측 _Sidebar 가 모든 관리/네비를 담당하므로 앱바 없음.
          appBar: AppPlatform.isDesktop
              ? null
              : AppBar(
                  title: Text(selectedGroup?.label ?? destination.label),
                  leading: Builder(
                    builder: (ctx) => IconButton(
                      key: const ValueKey('manage-drawer-button'),
                      icon: const Icon(Icons.menu),
                      tooltip: '그룹/카테고리 관리',
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
                  actions: [
                    IconButton(
                      key: const ValueKey('settings-button'),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: '설정',
                      onPressed: () => SettingsSheet.show(context),
                    ),
                  ],
                ),
          drawer: AppPlatform.isDesktop
              ? null
              : ManageDrawer(
                  onSelectCategory: _selectCategoryDestination,
                  onSelectGroup: _selectGroupFromDrawer,
                ),
          floatingActionButton: fab,
          // endFloat — Scaffold 가 FAB 를 bottomNavigationBar **위로** 띄워 네비를 가리지 않음.
          // (이전 endContained 는 nav bar 에 도킹돼 6개 destination 항목을 덮는 문제가 있었다.)
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: body,
          // desktop 은 좌측 _Sidebar 가 네비게이션을 담당해 bottomNavigationBar 가 의도적으로
          // null. mobile 만 NavigationBar 노출 — 오늘/전체보기/카테고리 3 슬롯 고정 (옵션 1).
          bottomNavigationBar: AppPlatform.isDesktop
              ? null
              : _buildMobileNavBar(destination, selectedGroup),
        ),
      ),
    );
  }
}

class _SelectDestinationIntent extends Intent {
  const _SelectDestinationIntent(this.digit);

  /// 0~6 단축키 digit. AppDestination.all 의 shortcutDigit 과 매핑.
  final int digit;
}

class _ShortcutsHost extends StatelessWidget {
  const _ShortcutsHost({
    required this.destinations,
    required this.onSelect,
    required this.child,
  });

  final List<AppDestination> destinations;
  final void Function(int digit) onSelect;
  final Widget child;

  /// 단축키 digit (0~9) ↔ LogicalKeyboardKey 매핑. destinations 의 shortcutDigit
  /// 이 동적이라 매 build 마다 활성 키만 추려서 Shortcuts map 만든다.
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
    }

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SelectDestinationIntent: _SelectDestinationAction(
            onSelect: onSelect,
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

/// 0~6 키 destination 전환 Action. **TextField focus 시 disabled** 되어 사용자가 todo
/// 제목에 숫자를 입력할 때 의도치 않은 전환이 발생하지 않게 한다.
class _SelectDestinationAction extends Action<_SelectDestinationIntent> {
  _SelectDestinationAction({required this.onSelect});

  final void Function(int digit) onSelect;

  @override
  bool isEnabled(_SelectDestinationIntent intent) => !isFocusInEditableText();

  @override
  Object? invoke(_SelectDestinationIntent intent) {
    onSelect(intent.digit);
    return null;
  }
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

/// 사이드바의 카테고리 그룹 선택 결과 (미분류 = null).
class _GroupChoice {
  const _GroupChoice(this.groupId);
  final String? groupId;
}

/// v1.3 — 데스크탑 사이드바. 그룹 헤더(접힘 가능) → 그 그룹의 카테고리 + 최상단
/// '미분류' 섹션 (groupId == null 카테고리). Today / Outline / 단축키 매핑은
/// [destinations] 의 index 를 그대로 사용 — 시각적 재배치일 뿐 selection 인덱싱은
/// 보존된다.
class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.destinations,
    required this.groups,
    required this.selectedIndex,
    required this.selectedGroupId,
    required this.onSelect,
    required this.onSelectGroup,
    required this.onDeleteCategory,
    required this.onMoveCategory,
    required this.onArchiveCategory,
    required this.onDeleteGroup,
    required this.onArchiveGroup,
    required this.onEditGroup,
    required this.onDropCategoryToGroup,
    required this.onMoveCategoryInto,
    required this.onReorderGroups,
  });

  final List<AppDestination> destinations;
  final List<Group> groups;
  final int selectedIndex;

  /// A안 — 선택된 그룹 id (없으면 null). non-null 이면 그 그룹 헤더가 강조되고
  /// today/category destination 의 선택 강조는 해제된다.
  final String? selectedGroupId;
  final ValueChanged<int> onSelect;

  /// 그룹 헤더 탭 → 그 그룹 화면 진입.
  final ValueChanged<String> onSelectGroup;
  final ValueChanged<AppDestination> onDeleteCategory;
  final ValueChanged<AppDestination> onMoveCategory;

  /// 카테고리 메뉴 '보관' — 활성 화면에서 숨김 (할 일 포함).
  final ValueChanged<AppDestination> onArchiveCategory;
  final ValueChanged<Group> onDeleteGroup;

  /// 그룹 메뉴 '보관' — 소속 카테고리·할 일까지 cascade 숨김.
  final ValueChanged<Group> onArchiveGroup;

  /// 그룹 헤더 메뉴 '이름·색 수정'.
  final ValueChanged<Group> onEditGroup;

  /// 드래그→드롭으로 카테고리를 그룹(groupId)/미분류(null)로 이동 (그룹 헤더/미분류 드롭).
  final void Function(Category category, String? groupId) onDropCategoryToGroup;

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

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  /// 아코디언 — 펼쳐진 그룹은 **한 번에 하나뿐**. null 이면 모두 접힘 (대표님 요청).
  /// 그룹 본문 탭(상세 진입) 또는 chevron 으로 그룹을 열면 나머지는 자동으로 접힌다.
  String? _expandedGroupId;

  /// 드래그 중인 카테고리가 hover 중인 drop target. group id(String) 또는
  /// 미분류 센티넬 [_ungroupedTargetKey]. 시각 피드백용.
  Object? _hoverTarget;

  /// '미분류' drop target 의 hover 키 (groupId == null 과 구분).
  static const Object _ungroupedTargetKey = Object();

  void _toggle(String groupId) {
    setState(() {
      // 이미 열린 그룹을 다시 누르면 닫고, 아니면 그 그룹만 열어 나머지를 닫는다.
      _expandedGroupId = _expandedGroupId == groupId ? null : groupId;
    });
  }

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
    final expanded = _expandedGroupId == g.id;
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
          // 본문 탭 — 그 그룹만 펼치고(나머지는 닫힘) 상세 진입.
          onSelect: () {
            setState(() => _expandedGroupId = g.id);
            widget.onSelectGroup(g.id);
          },
          onToggleCollapse: () => _toggle(g.id),
          hovering: _hoverTarget == g.id,
          onLongPress: () => _showGroupMenu(g),
          onWillAccept: () => setState(() => _hoverTarget = g.id),
          onLeave: () => setState(() => _hoverTarget = null),
          onAccept: (cat) {
            setState(() => _hoverTarget = null);
            widget.onDropCategoryToGroup(cat, g.id);
          },
        ),
        if (expanded && cats.isNotEmpty) _categorySection(cats),
      ],
    );
  }

  /// destination index → SidebarItem 위젯. 카테고리만 삭제/이동 컨텍스트 메뉴 + 드래그.
  Widget _item(int index, {Key? key}) {
    final dest = widget.destinations[index];
    final isCategory = dest.kind == DestinationKind.category;
    return SidebarItem(
      key: key,
      destination: dest,
      // 그룹 화면이 떠 있는 동안엔 destination 강조를 끈다.
      selected: widget.selectedGroupId == null && index == widget.selectedIndex,
      onTap: () => widget.onSelect(index),
      // 카테고리만 우클릭 / (드래그 불가 시) long-press 로 컨텍스트 메뉴 (삭제 / 그룹 이동).
      onLongPress: isCategory ? () => _showCategoryMenu(dest) : null,
      // 카테고리만 본문 길게누름 / ⠿ 로 드래그 이동·순서변경 가능 (E/K 통합).
      dragData: isCategory ? dest.category : null,
    );
  }

  /// 같은 그룹/미분류 섹션 — 각 행을 DragTarget 으로 감싸, 다른 카테고리를 그 행 위로
  /// 드롭하면 그 위치(앞)로 이동/순서변경(K, E 통합). 드래그 소스는 행 본문 길게누름
  /// 또는 ⠿ 핸들(SidebarItem 내부). 그룹 이동은 그룹 헤더/미분류 DragTarget 이 처리.
  Widget _categorySection(List<int> indices) {
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
            child: _item(indices[i]),
          ),
      ],
    );
  }

  /// 카테고리 long-press / 우클릭 메뉴 — 삭제 / 그룹 이동.
  Future<void> _showCategoryMenu(AppDestination dest) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('그룹 이동'),
              onTap: () => Navigator.of(ctx).pop('move'),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('보관'),
              subtitle: const Text('할 일과 함께 숨겨요'),
              onTap: () => Navigator.of(ctx).pop('archive'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: const Text('삭제'),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'move') {
      widget.onMoveCategory(dest);
    } else if (action == 'archive') {
      widget.onArchiveCategory(dest);
    } else if (action == 'delete') {
      widget.onDeleteCategory(dest);
    }
  }

  /// 그룹 헤더 long-press / 우클릭 메뉴 — 이름·색 수정 / 삭제. (그룹 삭제 시 속한
  /// 카테고리는 '미분류'로 이동되며 차단되지 않는다 — repo deleteById 의 detach 로직.)
  Future<void> _showGroupMenu(Group group) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('이름·색 수정'),
              onTap: () => Navigator.of(ctx).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('보관'),
              subtitle: const Text('카테고리·할 일까지 함께 숨겨요'),
              onTap: () => Navigator.of(ctx).pop('archive'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: Text("'${group.label}' 그룹 삭제"),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'edit') {
      widget.onEditGroup(group);
    } else if (action == 'archive') {
      widget.onArchiveGroup(group);
    } else if (action == 'delete') {
      widget.onDeleteGroup(group);
    }
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
        widget.onDropCategoryToGroup(details.data, null);
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
                    '여기로 드래그하면 그룹에서 빼요',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.4),
                      fontStyle: FontStyle.italic,
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

    // 카테고리 destination 들을 groupId 별로 분류 (index 보존).
    final ungrouped = <int>[];
    final byGroup = <String, List<int>>{};
    int? outlineIndex;
    int? todayIndex;
    int? timelineIndex;
    for (var i = 0; i < widget.destinations.length; i++) {
      final d = widget.destinations[i];
      switch (d.kind) {
        case DestinationKind.today:
          todayIndex = i;
          break;
        case DestinationKind.outline:
          outlineIndex = i;
          break;
        case DestinationKind.timeline:
          timelineIndex = i;
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
              key: const ValueKey('settings-button'),
              icon: const Icon(Icons.settings_outlined, size: 20),
              tooltip: '설정',
              visualDensity: VisualDensity.compact,
              onPressed: () => SettingsSheet.show(context),
            ),
          ],
        ),
      ),
      if (todayIndex != null) _item(todayIndex),
      // v1.4 (Task G) — 전체보기를 '오늘' 바로 다음으로 (카테고리/그룹 섹션 앞).
      if (outlineIndex != null) _item(outlineIndex),
      // v1.5 — 타임라인 (날짜 지정 항목 전역 뷰). 전체보기 다음.
      if (timelineIndex != null) _item(timelineIndex),
      // 미분류 섹션 — 그룹이 있으면 DragTarget(그룹 빼기)+라벨, 없으면 평면 리스트.
      if (widget.groups.isEmpty) ...[
        if (ungrouped.isNotEmpty) _categorySection(ungrouped),
      ] else
        _ungroupedSection(ungrouped, textTheme),
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
      // v1.5 — 카테고리/그룹 추가는 FAB(+) 의 "추가" 시트로 일원화됨 (대표님 요청).
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
    this.onLongPress,
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

  /// long-press / 우클릭 — 그룹 컨텍스트 메뉴 (수정 / 삭제). 카테고리 아이템과 동일 패턴.
  final VoidCallback? onLongPress;

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
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
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
    this.autofocus = false,
    this.dragData,
  });

  final AppDestination destination;
  final bool selected;
  final VoidCallback onTap;

  /// 우클릭 / (드래그 불가 시) long-press — 카테고리 컨텍스트 메뉴 진입점. null 이면 비활성.
  final VoidCallback? onLongPress;

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
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space8,
        vertical: AppTokens.space2,
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
            // 데스크탑의 우클릭은 항상 컨텍스트 메뉴 (삭제 / 그룹 이동 진입점).
            onSecondaryTap: widget.onLongPress,
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
                  if (draggable)
                    Draggable<Category>(
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
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (!draggable) return tile;
    // 길게 눌러 그룹 헤더/미분류로 드롭 → 그룹 이동(E). ⠿ 순서변경과 별개 제스처.
    return LongPressDraggable<Category>(
      data: widget.dragData!,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _CategoryDragFeedback(destination: widget.destination),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
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

class _MainArea extends StatelessWidget {
  const _MainArea({required this.destination});

  final AppDestination destination;

  @override
  Widget build(BuildContext context) {
    if (destination.isToday) return const HomeScreen();
    if (destination.isOutline) return const OutlineScreen();
    if (destination.isTimeline) return const TimelineScreen();
    return CategoryView(category: destination.category!);
  }
}

/// FAB / Cmd+N 추가 선택 시트의 결과.
enum _AddAction { todo, category, group }

/// FAB / Cmd+N 진입 시 먼저 뜨는 "무엇을 추가할까요?" 하단 시트 (대표님 요청).
/// 새 할일 / 카테고리 / 그룹 3 동선을 한곳에 모은다 — Drawer 의 추가 버튼들은 제거됨.
class _AddActionSheet extends StatelessWidget {
  const _AddActionSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space12,
          AppTokens.space8,
          AppTokens.space12,
          AppTokens.space16,
        ),
        child: Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(AppTokens.radiusL),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 드래그 핸들
              Container(
                margin: const EdgeInsets.only(top: AppTokens.space8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space16,
                  AppTokens.space16,
                  AppTokens.space16,
                  AppTokens.space8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '무엇을 추가할까요?',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              _AddActionTile(
                valueKey: 'add-action-todo',
                icon: Icons.check_circle_outline,
                color: scheme.primary,
                title: '새 할 일',
                subtitle: '할 일을 추가합니다',
                onTap: () => Navigator.of(context).pop(_AddAction.todo),
              ),
              _AddActionTile(
                valueKey: 'add-action-category',
                icon: Icons.label_outline,
                color: const Color(0xFFF97316),
                title: '카테고리 추가',
                subtitle: '새 분류를 만듭니다',
                onTap: () => Navigator.of(context).pop(_AddAction.category),
              ),
              _AddActionTile(
                valueKey: 'add-action-group',
                icon: Icons.create_new_folder_outlined,
                color: const Color(0xFF8B5CF6),
                title: '그룹 추가',
                subtitle: '카테고리를 묶는 그룹을 만듭니다',
                onTap: () => Navigator.of(context).pop(_AddAction.group),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddActionTile extends StatelessWidget {
  const _AddActionTile({
    required this.valueKey,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String valueKey;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      key: ValueKey(valueKey),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space16,
          vertical: AppTokens.space12,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: AppTokens.space16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppTokens.space2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}
