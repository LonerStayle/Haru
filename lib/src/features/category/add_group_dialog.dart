import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/group.dart';
import 'groups_controller.dart';

const _uuid = Uuid();

/// 그룹 추가/수정 다이얼로그. [AddCategoryDialog] 미러 (아이콘 picker 는 생략 — 그룹은
/// 사이드바 헤더에 색 dot + label 만 쓴다).
///
/// label TextField + 16 색 palette. 확인 시 [GroupsController.add] 호출 (upsert).
/// 신규: id 는 `grp-<uuid>`, sortOrder 100. 수정([existing] 주입): 같은 id 로 label/color
/// 만 갱신하고 sortOrder/isBuiltin 은 보존한다.
class AddGroupDialog extends ConsumerStatefulWidget {
  const AddGroupDialog({super.key, this.existing});

  /// non-null 이면 **수정 모드** — 이 그룹의 label/color 를 프리필하고 같은 id 로 upsert.
  final Group? existing;

  /// 추가 다이얼로그 표시 + 결과 반환 (true = 추가됨, false/null = 취소).
  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const AddGroupDialog(),
    );
  }

  /// 수정 다이얼로그 표시 — [group] 의 label/color 프리필. (true = 저장됨).
  static Future<bool?> showEdit(BuildContext context, Group group) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AddGroupDialog(existing: group),
    );
  }

  /// 사용자가 고를 16 색 palette (AddCategoryDialog 와 동일 세트).
  @visibleForTesting
  static const colorPalette = <int>[
    0xFFEC4899, // pink
    0xFFF97316, // orange
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

  @override
  ConsumerState<AddGroupDialog> createState() => _AddGroupDialogState();
}

class _AddGroupDialogState extends ConsumerState<AddGroupDialog> {
  late final _labelCtrl = TextEditingController(
    text: widget.existing?.label ?? '',
  );
  late int _selectedColor =
      widget.existing?.colorValue ?? AddGroupDialog.colorPalette.first;
  bool _submitted = false;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  /// 같은 이름(대소문자·앞뒤 공백 무시)의 다른 그룹이 있는지 (보관 포함).
  bool get _isDuplicate => _duplicate != null;

  /// 이름이 겹치는 다른 그룹 (보관 포함) — 없으면 null.
  dynamic get _duplicate {
    final label = _labelCtrl.text.trim().toLowerCase();
    if (label.isEmpty) return null;
    final all = ref.read(groupsProvider).asData?.value ?? const [];
    for (final g in all) {
      if (g.id != widget.existing?.id &&
          g.label.trim().toLowerCase() == label) {
        return g;
      }
    }
    return null;
  }

  /// 중복 안내 — 보관된 것과 겹치면 어디 있는지 알려 준다(목록에 안 보이므로).
  String? get _duplicateMessage {
    final d = _duplicate;
    if (d == null) return null;
    return d.archived == true ? '보관함에 같은 이름의 그룹이 있어요' : '같은 이름의 그룹이 이미 있어요';
  }

  bool get _canSubmit =>
      _labelCtrl.text.trim().isNotEmpty && !_isDuplicate && !_submitted;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitted = true);
    final controller = ref.read(groupsControllerProvider);
    // 신규는 맨 뒤로 — 전체 최대 sortOrder + 1.
    final all = ref.read(groupsProvider).asData?.value ?? const [];
    var nextOrder = 100;
    for (final g in all) {
      if (g.sortOrder + 1 > nextOrder) nextOrder = g.sortOrder + 1;
    }

    // 수정 모드면 같은 id 로 label/color 만 갱신 (sortOrder/isBuiltin 보존).
    // 신규면 새 id 발급. add() 는 upsert 라 둘 다 동일 경로.
    final group =
        widget.existing?.copyWith(
          label: _labelCtrl.text.trim(),
          colorValue: _selectedColor,
        ) ??
        Group(
          id: 'grp-${_uuid.v4()}',
          label: _labelCtrl.text.trim(),
          colorValue: _selectedColor,
          sortOrder: nextOrder,
          isBuiltin: false,
        );
    await controller.add(group);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 중복 이름 검사·다음 순서 계산이 읽는 전체 목록 — 구독해 둬야 값이 채워진다.
    ref.watch(groupsProvider);
    return AlertDialog(
      title: Text(_isEdit ? '그룹 수정' : '새 그룹'),
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
                decoration: InputDecoration(
                  labelText: '이름',
                  hintText: '예: 회사, 사이드프로젝트',
                  errorText: _duplicateMessage,
                ),
                onChanged: (_) => setState(() {}),
                // 카테고리 다이얼로그와 같이 Enter 로 바로 저장.
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AppTokens.space16),
              Text('색', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppTokens.space8),
              _ColorPalette(
                colors: AddGroupDialog.colorPalette,
                selected: _selectedColor,
                onSelect: (c) => setState(() => _selectedColor = c),
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
          child: Text(_isEdit ? '저장' : '추가'),
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
              width: AppPlatform.isMobile ? 44 : 36,
              height: AppPlatform.isMobile ? 44 : 36,
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
              // 선택 표시를 테두리 색에만 기대지 않도록 체크 글리프 병행 (색각 이상 대응).
              child: c == selected
                  ? const Icon(Icons.check, size: 18, color: Colors.white)
                  : null,
            ),
          ),
      ],
    );
  }
}
