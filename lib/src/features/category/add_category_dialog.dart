import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme.dart';
import '../../domain/category.dart';
import '../../domain/group.dart';
import 'categories_controller.dart';
import 'groups_controller.dart';

const _uuid = Uuid();

/// 새 카테고리 추가 다이얼로그.
///
/// label TextField + 16 색 palette + Material Icons picker (builtin 5종 + 일상 모음).
/// 확인 시 [CategoriesController.add] 호출. id 는 `cat-<uuid>` 로 부여 (builtin 의
/// 'work' / 'personal_dev' 등과 충돌 회피).
class AddCategoryDialog extends ConsumerStatefulWidget {
  const AddCategoryDialog({super.key});

  /// 다이얼로그 표시 + 결과 반환 (true = 추가됨, false/null = 취소).
  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const AddCategoryDialog(),
    );
  }

  /// 사용자가 고를 16 색 palette. 일관성을 위해 builtin 5종 색은 포함하지 않음.
  @visibleForTesting
  static const colorPalette = <int>[
    0xFFEC4899, // pink
    0xFFF97316, // orange (builtin 'idea' 와 hue 유사하나 채도 차이로 구분)
    0xFF84CC16, // lime
    0xFF06B6D4, // cyan
    0xFF3B82F6, // blue
    0xFF6366F1, // indigo
    0xFFA855F7, // violet
    0xFFD946EF, // fuchsia
    0xFFF43F5E, // rose
    0xFF14B8A6, // teal
    0xFF22C55E, // green
    0xFF65A30D, // dark lime
    0xFF0EA5E9, // sky
    0xFF7C3AED, // purple
    0xFFE11D48, // dark rose
    0xFF6B7280, // gray
  ];

  /// 사용자가 고를 Material Icons codepoint.
  ///
  /// 맨 앞 5종은 builtin 카테고리(회사/개인개발/일상/장기목표/아이디어)가 쓰는
  /// 아이콘과 동일 — 새 카테고리에서도 기본 카테고리와 같은 아이콘을 고를 수 있게 함.
  /// ⚠️ 이 5개는 [Category.builtinSeeds] 의 iconCodePoint 와 항상 일치시켜야 한다.
  /// 나머지는 업무/학습/사람/건강/지출/취미/장소 등 일상 카테고리용 모음.
  @visibleForTesting
  static const iconPalette = <int>[
    // ── builtin 카테고리 5종 아이콘 (정렬 순서대로) ──
    0xef0a, // business_center_outlined (회사 할일)
    0xe176, // code (개인개발)
    0xf107, // home_outlined (일상)
    0xf07b, // flag_outlined (장기 목표)
    0xe37c, // lightbulb_outline (아이디어)
    // ── 업무 / 일정 ──
    0xe6f4, // work_outline
    0xe15b, // checklist
    0xe66a, // today
    0xe072, // alarm
    0xe25c, // event_outlined
    // ── 학습 / 독서 ──
    0xe865, // book
    0xe87c, // bookmark
    0xe53e, // school
    // ── 사람 / 관심 ──
    0xe7fd, // person
    0xe7ef, // group
    0xe25b, // favorite
    0xe4a1, // pets
    // ── 건강 / 생활 ──
    0xe28d, // fitness_center
    0xe1dc, // directions_run
    0xe56f, // self_improvement
    0xe167, // cleaning_services
    // ── 지출 / 쇼핑 ──
    0xe1aa, // attach_money
    0xe553, // savings
    0xe59c, // shopping_cart
    // ── 취미 / 여가 ──
    0xe430, // music_note
    0xe40d, // movie
    0xe038, // games
    0xe5e8, // sports_esports
    0xe113, // brush
    0xe410, // photo
    // ── 음식 / 장소 / 여행 ──
    0xe558, // restaurant
    0xe38d, // local_cafe
    0xe55b, // place
    0xe297, // flight
    0xe5f9, // star
  ];

  @override
  ConsumerState<AddCategoryDialog> createState() => _AddCategoryDialogState();
}

class _AddCategoryDialogState extends ConsumerState<AddCategoryDialog> {
  final _labelCtrl = TextEditingController();
  int _selectedColor = AddCategoryDialog.colorPalette.first;
  int _selectedIcon = AddCategoryDialog.iconPalette.first;
  // null = '미분류'. 사용자가 그룹 dropdown 에서 선택하면 해당 Group.id.
  String? _selectedGroupId;
  bool _submitted = false;

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit => _labelCtrl.text.trim().isNotEmpty && !_submitted;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitted = true);
    final controller = ref.read(categoriesControllerProvider);

    // 사용자 카테고리는 sortOrder 100 + 임의 (= 항상 builtin 뒤). 정렬 미세조정은 v1.3.
    final newCategory = Category(
      id: 'cat-${_uuid.v4()}',
      label: _labelCtrl.text.trim(),
      iconCodePoint: _selectedIcon,
      colorValue: _selectedColor,
      sortOrder: 100,
      isBuiltin: false,
      groupId: _selectedGroupId,
    );
    await controller.add(newCategory);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('새 카테고리'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _labelCtrl,
                autofocus: true,
                maxLength: 30,
                decoration: const InputDecoration(
                  labelText: '이름',
                  hintText: '예: 독서, 운동',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppTokens.space16),
              Text('색', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppTokens.space8),
              _ColorPalette(
                colors: AddCategoryDialog.colorPalette,
                selected: _selectedColor,
                onSelect: (c) => setState(() => _selectedColor = c),
              ),
              const SizedBox(height: AppTokens.space16),
              Text('아이콘', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppTokens.space8),
              _IconPalette(
                codePoints: AddCategoryDialog.iconPalette,
                selected: _selectedIcon,
                selectedColor: Color(_selectedColor),
                onSelect: (cp) => setState(() => _selectedIcon = cp),
              ),
              const SizedBox(height: AppTokens.space16),
              Text('그룹', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppTokens.space4),
              Text(
                '이 카테고리가 들어갈 그룹을 골라요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: AppTokens.space8),
              _GroupPicker(
                selectedGroupId: _selectedGroupId,
                groups:
                    ref.watch(activeGroupsProvider).asData?.value ?? const [],
                onSelect: (id) => setState(() => _selectedGroupId = id),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitted ? null : () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('추가'),
        ),
      ],
    );
  }
}

class _ColorPalette extends StatelessWidget {
  const _ColorPalette({
    required this.colors,
    required this.selected,
    required this.onSelect,
  });

  final List<int> colors;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final c in colors)
          GestureDetector(
            onTap: () => onSelect(c),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(
                  color: c == selected
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.transparent,
                  width: 2.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 그룹 선택 picker — '미분류'(null) + 사용자 그룹들을 chip 으로 나열해 택1.
///
/// (이전엔 dropdown 이었으나 선택지가 collapsed 라 '어느 그룹인지' 한눈에 안 들어와
/// chip 그리드로 교체.) 그룹이 하나도 없으면 '미분류' chip 하나만 노출된다.
class _GroupPicker extends StatelessWidget {
  const _GroupPicker({
    required this.selectedGroupId,
    required this.groups,
    required this.onSelect,
  });

  final String? selectedGroupId;
  final List<Group> groups;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        _GroupChoiceChip(
          key: const ValueKey('group-choice-none'),
          label: '미분류',
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          selected: selectedGroupId == null,
          onTap: () => onSelect(null),
        ),
        for (final g in groups)
          _GroupChoiceChip(
            key: ValueKey('group-choice-${g.id}'),
            label: g.label,
            color: g.color,
            selected: selectedGroupId == g.id,
            onTap: () => onSelect(g.id),
          ),
      ],
    );
  }
}

/// 그룹 선택 chip 한 개 — 색 dot + 라벨. 선택 시 outline + 채워진 배경.
class _GroupChoiceChip extends StatelessWidget {
  const _GroupChoiceChip({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = selected
        ? color.withValues(alpha: 0.20)
        : scheme.surfaceContainerHighest;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      side: selected ? BorderSide(color: color, width: 1.6) : BorderSide.none,
    );
    return Material(
      color: bg,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space12,
            vertical: AppTokens.space8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // BoxShape.circle Container 대신 Icon — 색상환 테스트(16색)와 충돌 회피.
              Icon(Icons.circle, size: 12, color: color),
              const SizedBox(width: AppTokens.space8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurface.withValues(alpha: 0.78),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconPalette extends StatelessWidget {
  const _IconPalette({
    required this.codePoints,
    required this.selected,
    required this.selectedColor,
    required this.onSelect,
  });

  final List<int> codePoints;
  final int selected;
  final Color selectedColor;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: AppTokens.space8,
      runSpacing: AppTokens.space8,
      children: [
        for (final cp in codePoints)
          InkWell(
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
            onTap: () => onSelect(cp),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: cp == selected
                    ? selectedColor.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
                border: Border.all(
                  color: cp == selected ? selectedColor : scheme.outlineVariant,
                  width: cp == selected ? 1.6 : 1,
                ),
              ),
              child: Icon(
                // ignore: non_const_argument_for_const_parameter
                IconData(cp, fontFamily: 'MaterialIcons'),
                color: cp == selected ? selectedColor : scheme.onSurface,
                size: 20,
              ),
            ),
          ),
      ],
    );
  }
}
