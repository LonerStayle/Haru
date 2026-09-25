import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../auth/auth_providers.dart';
import '../calendar/calendar_event.dart';
import '../calendar/calendar_settings.dart';
import '../calendar/calendar_settings_screen.dart';
import '../calendar/google_auth_service.dart';
import '../calendar/microsoft_auth_service.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import '../../domain/policies/todo_sort_policy.dart';
import '../recurrence/recurrence_manage_screen.dart';
import 'app_preferences.dart';
import 'archive_screen.dart';
import 'launch_at_login_service.dart';
import 'sort_mode_controller.dart';

/// 앱 설정 — 섹션: 계정 · 일반 · 캘린더 연동 · 데이터 · 정보.
///
/// 데스크탑은 ⌘, 로 여는 가운데 대화상자(폭 600), 폰은 전체 화면 페이지. (예전엔
/// 항목 몇 개가 섹션 없이 나열된 하단 시트였다.)
///
/// 자동 실행 토글은 [LaunchAtLoginService] (네이티브 SMAppService) 를 호출하며,
/// 네이티브가 보고한 **실제 상태**로 UI 를 갱신한다. 실패 시 스낵바 안내 후 롤백.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    this.launchService = const LaunchAtLoginService(),
  });

  /// 테스트에서 대체 주입 가능.
  final LaunchAtLoginService launchService;

  static Future<void> show(BuildContext context) {
    if (AppPlatform.isDesktop) {
      return showDialog<void>(
        context: context,
        builder: (context) {
          final size = MediaQuery.sizeOf(context);
          return Dialog(
            insetPadding: const EdgeInsets.all(AppTokens.space24),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 600,
                maxHeight: size.height * 0.86,
              ),
              child: const SettingsSheet(),
            ),
          );
        },
      );
    }
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsSheet()));
  }

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  bool _loading = true;
  bool _enabled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (AppPlatform.isDesktop) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    final enabled = await widget.launchService.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.launchService.setEnabled(value);
      if (!mounted) return;
      setState(() {
        _enabled = result;
        _busy = false;
      });
    } on LaunchAtLoginException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop = AppPlatform.isDesktop;

    final sections = <Widget>[
      // 로그인 계정 + 로그아웃 — 로그인 상태일 때만 (섹션 제목 포함).
      const _AccountTile(),
      const _SectionHeader('일반'),
      if (desktop) _autoLaunchTile(theme, scheme),
      const _ThemeTile(),
      const _DefaultCategoryTile(),
      const _SortModeTile(),
      if (desktop) const _ShortcutsTile(),
      const _CalendarSectionHeader(),
      _calendarTile(theme, scheme),
      _microsoftCalendarTile(theme, scheme),
      const _SectionHeader('데이터'),
      _archiveTile(theme, scheme),
      const _RecurrenceTile(),
      const _SectionHeader('정보'),
      const _VersionTile(),
      const SizedBox(height: AppTokens.space16),
    ];

    if (!desktop) {
      return Scaffold(
        appBar: AppBar(title: const Text('설정')),
        body: ListView(
          key: const ValueKey('settings-list'),
          children: sections,
        ),
      );
    }
    return Material(
      color: scheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space24,
              AppTokens.space16,
              AppTokens.space12,
              AppTokens.space8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '설정',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('settings-close'),
                  icon: const Icon(Icons.close),
                  tooltip: '닫기 (Esc)',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: AppTokens.hairline),
          Flexible(
            child: ListView(
              key: const ValueKey('settings-list'),
              shrinkWrap: true,
              children: sections,
            ),
          ),
        ],
      ),
    );
  }

  Widget _autoLaunchTile(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space16,
        vertical: AppTokens.space8,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTokens.radiusM),
            ),
            child: Icon(
              Icons.power_settings_new_rounded,
              color: scheme.primary,
              size: 24,
            ),
          ),
          const SizedBox(width: AppTokens.space16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '로그인 시 자동 실행',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppTokens.space2),
                Text(
                  'Mac을 켜면 하루가 자동으로 실행돼요.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.space12),
          if (_loading || _busy)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch.adaptive(
              key: const ValueKey('launch-at-login-switch'),
              value: _enabled,
              onChanged: _toggle,
            ),
        ],
      ),
    );
  }

  /// Google Calendar 연동 진입 — 연결 상태를 부제로 보여준다.
  ///
  /// OAuth 키가 빌드에 없으면 (`googleCalendarAvailableProvider == false`) 항목
  /// 자체를 숨긴다. 눌러봐야 아무것도 할 수 없는 항목을 보여줄 이유가 없다.
  Widget _calendarTile(ThemeData theme, ColorScheme scheme) => _calendarEntry(
    theme,
    scheme,
    provider: CalendarProvider.google,
    entryKey: const ValueKey('calendar-entry'),
    icon: Icons.event_outlined,
  );

  /// Microsoft 365 (Teams) 연동 진입. Azure 클라이언트 ID 가 없으면 숨겨진다.
  Widget _microsoftCalendarTile(ThemeData theme, ColorScheme scheme) =>
      _calendarEntry(
        theme,
        scheme,
        provider: CalendarProvider.microsoft,
        entryKey: const ValueKey('microsoft-calendar-entry'),
        icon: Icons.groups_outlined,
      );

  /// 두 서비스가 같은 모양의 항목을 쓴다 — 하나만 고치고 다른 쪽을 빠뜨리는 일을 막는다.
  Widget _calendarEntry(
    ThemeData theme,
    ColorScheme scheme, {
    required CalendarProvider provider,
    required Key entryKey,
    required IconData icon,
  }) {
    return Consumer(
      builder: (context, ref, _) {
        final available = provider == CalendarProvider.microsoft
            ? ref.watch(microsoftCalendarAvailableProvider)
            : ref.watch(googleCalendarAvailableProvider);
        if (!available) return const SizedBox.shrink();
        final connected = ref.watch(
          calendarSettingsProvider.select((s) => s.viewFor(provider).connected),
        );

        return InkWell(
          key: entryKey,
          onTap: () => CalendarSettingsScreen.show(context, provider: provider),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.space16,
              vertical: AppTokens.space8,
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(AppTokens.radiusM),
                  ),
                  child: Icon(
                    icon,
                    size: 22,
                    color: scheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: AppTokens.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.label,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        connected
                            ? '연결됨 · 할 일과 일정이 함께 움직여요'
                            : '연결하면 일정이 함께 움직여요',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 보관함 진입 — 보관된 그룹/카테고리 개수를 배지로 보여주고 [ArchiveScreen] 으로 이동.
  /// (Consumer 로 감싸 count 를 reactive 하게 반영 — 보관/복원 시 즉시 갱신.)
  Widget _archiveTile(ThemeData theme, ColorScheme scheme) {
    return Consumer(
      builder: (context, ref, _) {
        final archivedGroups =
            ref.watch(archivedGroupsProvider).asData?.value ?? const <Group>[];
        final archivedCats =
            ref.watch(archivedCategoriesProvider).asData?.value ??
            const <Category>[];
        final archivedGroupIds = archivedGroups.map((g) => g.id).toSet();
        // 보관 그룹에 포함된 카테고리는 그룹 항목으로 대표되므로 개수에서 제외.
        final standalone = archivedCats
            .where(
              (c) => c.groupId == null || !archivedGroupIds.contains(c.groupId),
            )
            .length;
        final count = archivedGroups.length + standalone;

        return InkWell(
          key: const ValueKey('archive-entry'),
          onTap: () => ArchiveScreen.show(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTokens.space16,
              vertical: AppTokens.space8,
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(AppTokens.radiusM),
                  ),
                  child: Icon(
                    Icons.inventory_2_outlined,
                    color: scheme.onSurface.withValues(alpha: 0.7),
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppTokens.space16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '보관함',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppTokens.space2),
                      Text(
                        count > 0
                            ? '보관된 항목 $count개 · 복원할 수 있어요'
                            : '보관된 항목이 없어요',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (count > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space8,
                      vertical: AppTokens.space2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                    ),
                    child: Text(
                      '$count',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                const SizedBox(width: AppTokens.space4),
                Icon(
                  Icons.chevron_right,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 로그인한 계정 이메일 + 로그아웃 버튼. Supabase 미사용(로컬 전용)이거나 로그아웃
/// 상태면 아무것도 그리지 않는다.
class _AccountTile extends ConsumerWidget {
  const _AccountTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final email = user.email ?? '로그인됨';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('계정'),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space16,
            vertical: AppTokens.space8,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTokens.radiusM),
                ),
                child: Icon(
                  Icons.account_circle_outlined,
                  color: scheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: AppTokens.space16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('계정', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const ValueKey('sign-out-button'),
                onPressed: () => _confirmSignOut(context, ref),
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                child: const Text('로그아웃'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final pending = ref.read(outboxCountProvider).value ?? 0;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('로그아웃할까요?'),
            content: Text(
              pending > 0
                  ? '아직 서버에 올라가지 않은 변경 $pending건은 이 기기에서 사라져요.\n'
                        '다시 로그인하면 서버에 있는 할 일은 그대로 돌아와요.'
                  : '이 기기의 할 일 목록을 지우고 로그인 화면으로 돌아가요.\n'
                        '다시 로그인하면 서버에 있는 할 일이 그대로 돌아와요.',
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
                child: const Text('로그아웃'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !context.mounted) return;
    // 설정을 먼저 닫는다 — 로그아웃되면 _AuthGate 가 AppShell 을 SignInScreen 으로
    // 바꾸므로, 시트가 열린 채면 사라진 화면 위에 떠 있게 된다.
    // ref 는 시트가 닫히며 dispose 되므로 컨트롤러를 먼저 잡아 둔다.
    final signOut = ref.read(signOutControllerProvider);
    Navigator.of(context).pop();
    await signOut.signOutAndClear();
  }
}

/// 섹션 제목 — 작은 회색 글씨.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('settings-section-$label'),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space20,
        AppTokens.space16,
        AppTokens.space4,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// 캘린더 연동 섹션 제목 — 연동할 수 있는 서비스가 하나도 없으면(키 없는 빌드) 숨긴다.
class _CalendarSectionHeader extends ConsumerWidget {
  const _CalendarSectionHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final any =
        ref.watch(googleCalendarAvailableProvider) ||
        ref.watch(microsoftCalendarAvailableProvider);
    return any ? const _SectionHeader('캘린더 연동') : const SizedBox.shrink();
  }
}

/// 설정 한 줄 — 아이콘 · 제목 · 부제 · 오른쪽 조작.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.below,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 폭이 좁을 때 오른쪽 대신 아래 줄에 둘 조작(세그먼트 등).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space16,
        vertical: AppTokens.space8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(AppTokens.radiusM),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: scheme.onSurface.withValues(alpha: 0.7),
                ),
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
                    if (subtitle != null) ...[
                      const SizedBox(height: AppTokens.space2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppTokens.space12),
                trailing!,
              ],
            ],
          ),
          if (below != null)
            Padding(
              padding: const EdgeInsets.only(
                left: 40 + AppTokens.space16,
                top: AppTokens.space8,
              ),
              child: Align(alignment: Alignment.centerLeft, child: below),
            ),
        ],
      ),
    );
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }
}

/// 테마 — 시스템 / 라이트 / 다크.
class _ThemeTile extends ConsumerWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return _SettingRow(
      icon: Icons.brightness_6_outlined,
      title: '테마',
      subtitle: '기본은 기기 설정을 따라가요',
      below: SegmentedButton<ThemeMode>(
        key: const ValueKey('settings-theme'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: ThemeMode.system, label: Text('시스템')),
          ButtonSegment(value: ThemeMode.light, label: Text('라이트')),
          ButtonSegment(value: ThemeMode.dark, label: Text('다크')),
        ],
        selected: {mode},
        onSelectionChanged: (s) =>
            ref.read(themeModeProvider.notifier).set(s.first),
      ),
    );
  }
}

/// 새 할 일의 기본 카테고리 — 오늘·전체보기·캘린더에서 추가할 때.
class _DefaultCategoryTile extends ConsumerWidget {
  const _DefaultCategoryTile();

  static const String _auto = '__auto__';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ?? const <Category>[];
    final id = ref.watch(defaultCategoryIdProvider);
    final current = categories.where((c) => c.id == id).firstOrNull;
    return _SettingRow(
      icon: Icons.label_outline,
      title: '새 할 일 기본 카테고리',
      subtitle: '카테고리 화면에서 추가하면 그 카테고리가 먼저예요',
      trailing: PopupMenuButton<String>(
        key: const ValueKey('settings-default-category'),
        tooltip: '기본 카테고리 고르기',
        initialValue: current?.id ?? _auto,
        onSelected: (v) => ref
            .read(defaultCategoryIdProvider.notifier)
            .set(v == _auto ? null : v),
        itemBuilder: (context) => [
          const PopupMenuItem(value: _auto, child: Text('마지막에 쓴 카테고리')),
          for (final c in categories)
            PopupMenuItem(
              value: c.id,
              child: Row(
                children: [
                  Icon(c.icon, size: 16, color: c.color),
                  const SizedBox(width: AppTokens.space8),
                  Text(c.label),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space8,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (current != null) ...[
                Icon(current.icon, size: 16, color: current.color),
                const SizedBox(width: AppTokens.space4),
              ],
              Text(current?.label ?? '마지막에 쓴 카테고리'),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }
}

/// 목록 정렬 기본값 — 목록 머리의 정렬 버튼과 같은 설정(모든 목록에 적용).
class _SortModeTile extends ConsumerWidget {
  const _SortModeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(sortModeProvider);
    return _SettingRow(
      icon: Icons.sort_rounded,
      title: '목록 정렬',
      subtitle: '모든 목록에 적용돼요 · 목록 머리의 정렬 버튼과 같아요',
      below: SegmentedButton<TodoSortMode>(
        key: const ValueKey('settings-sort-mode'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: TodoSortMode.manual, label: Text('직접 정한 순서')),
          ButtonSegment(value: TodoSortMode.dueDate, label: Text('일정순')),
        ],
        selected: {mode},
        onSelectionChanged: (s) =>
            ref.read(sortModeProvider.notifier).setMode(s.first),
      ),
    );
  }
}

/// 단축키 목록 (데스크탑).
class _ShortcutsTile extends StatelessWidget {
  const _ShortcutsTile();

  static const List<(String, String)> shortcuts = [
    ('⌘N', '새 할 일 (하루 창 안에서)'),
    ('⌘⇧N', '새 할 일 (어디서나)'),
    ('⌘K · ⌘F', '검색'),
    ('⌘,', '설정'),
    ('⌘0 ~ ⌘9', '화면 전환 (오늘 · 전체보기 · 캘린더 · 카테고리)'),
    ('⌘Z', '방금 한 일 되돌리기'),
    ('⌘↩', '시트 저장'),
    ('Esc', '시트 · 패널 · 검색 닫기'),
    ('← →  ·  T', '캘린더 달 이동 · 오늘로'),
    ('칸 두 번 클릭', '캘린더에서 그 날짜로 새 할 일'),
  ];

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      key: const ValueKey('settings-shortcuts'),
      icon: Icons.keyboard_outlined,
      title: '단축키',
      subtitle: '⌘N 새 할 일 · ⌘K 검색 · ⌘Z 되돌리기 …',
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('settings-shortcuts-dialog'),
          title: const Text('단축키'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (keys, what) in shortcuts)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppTokens.space4,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 130,
                          child: Text(
                            keys,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Expanded(child: Text(what)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('닫기'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 반복 일정 관리 진입 (예전엔 오늘 화면 머리의 🔁 아이콘뿐이었다).
class _RecurrenceTile extends StatelessWidget {
  const _RecurrenceTile();

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      key: const ValueKey('settings-recurrence'),
      icon: Icons.repeat_rounded,
      title: '반복 일정',
      subtitle: '반복 중인 할 일을 보고 멈출 수 있어요',
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const RecurrenceManageScreen()),
      ),
    );
  }
}

/// 앱 이름 · 버전 — 빌드에 박힌 실제 버전을 읽는다(예전엔 v1.0.0 고정 문구).
class _VersionTile extends StatefulWidget {
  const _VersionTile();

  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(
        () => _version = info.buildNumber.isEmpty
            ? info.version
            : '${info.version} (${info.buildNumber})',
      );
    } catch (_) {
      // 플랫폼 정보를 못 읽으면 버전 없이 이름만.
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SettingRow(
      key: const ValueKey('settings-version'),
      icon: Icons.info_outline_rounded,
      title: '하루',
      subtitle: _version == null ? null : '버전 $_version',
    );
  }
}
