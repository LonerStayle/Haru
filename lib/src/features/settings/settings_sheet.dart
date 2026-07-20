import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import '../category/categories_controller.dart';
import '../category/groups_controller.dart';
import 'archive_screen.dart';
import 'launch_at_login_service.dart';

/// 앱 설정 하단 시트. 현재 항목:
///   - (데스크탑) macOS 로그인 시 자동 실행 토글 — 기본 꺼짐.
///   - 앱 정보 (이름 · 버전).
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
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const SettingsSheet(),
    );
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: AppTokens.space8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  ),
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
                    '설정',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (AppPlatform.isDesktop) ...[
                _autoLaunchTile(theme, scheme),
                const Divider(height: AppTokens.hairline),
              ],
              _archiveTile(theme, scheme),
              const Divider(height: AppTokens.hairline),
              _infoTile(theme, scheme),
              const SizedBox(height: AppTokens.space8),
            ],
          ),
        ),
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
            width: 44,
            height: 44,
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
                  width: 44,
                  height: 44,
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

  Widget _infoTile(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space16,
        vertical: AppTokens.space12,
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(width: AppTokens.space12),
          Text(
            '하루 · v1.0.0',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
