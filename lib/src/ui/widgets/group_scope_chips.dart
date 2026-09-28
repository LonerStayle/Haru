import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/group.dart';
import '../../features/category/groups_controller.dart';
import '../shell_state.dart';

/// 활성 그룹 중 [groupScopeProvider] 가 가리키는 그룹 — 없거나 사라졌으면 null.
final scopedGroupProvider = Provider<Group?>((ref) {
  final id = ref.watch(groupScopeProvider);
  if (id == null) return null;
  final groups = ref.watch(activeGroupsProvider).asData?.value;
  if (groups == null) return null;
  for (final g in groups) {
    if (g.id == id) return g;
  }
  return null;
});

/// 그룹 필터 칩 한 줄 — `[전체] [회사] [개인] …`. 오늘·전체보기 상단.
///
/// 예전 "그룹 화면"([오늘|전체보기] 탭)을 대신한다. 두 화면이 같은 필터를 공유하므로
/// 오늘에서 '회사' 를 고르면 전체보기도 회사만 보인다. 그룹이 없으면 아무것도 그리지
/// 않는다.
class GroupScopeChips extends ConsumerWidget {
  const GroupScopeChips({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];
    if (groups.isEmpty) return const SizedBox.shrink();
    final selected = ref.watch(scopedGroupProvider)?.id;
    final notifier = ref.read(groupScopeProvider.notifier);

    return SingleChildScrollView(
      key: const ValueKey('group-scope-chips'),
      scrollDirection: Axis.horizontal,
      primary: false,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: AppTokens.space16),
      child: Row(
        children: [
          _ScopeChip(
            key: const ValueKey('group-scope-all'),
            // '전체' 는 상태 칩(전체 N)과 겹쳐 헷갈린다 → 그룹 축임을 이름에.
            label: '모든 그룹',
            color: null,
            selected: selected == null,
            onTap: () => notifier.set(null),
          ),
          for (final g in groups) ...[
            const SizedBox(width: AppTokens.space8),
            _ScopeChip(
              key: ValueKey('group-scope-${g.id}'),
              label: g.label,
              color: g.color,
              selected: selected == g.id,
              // 이미 고른 그룹을 다시 누르면 전체로 — 되돌리기 쉬운 토글.
              onTap: () => notifier.set(selected == g.id ? null : g.id),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = color ?? scheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? accent.withValues(alpha: 0.16)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          side: BorderSide(
            color: selected ? accent : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (color != null) ...[
                    Icon(Icons.circle, size: 10, color: color),
                    const SizedBox(width: AppTokens.space8),
                  ],
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
