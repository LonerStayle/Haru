import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform.dart';
import '../../../core/theme.dart';
import '../../../domain/category.dart';
import '../ai_json.dart';
import '../ai_providers.dart';
import '../widgets/ai_inline_error.dart';
import 'ai_paste_organizer.dart';

/// 패널 결과 — 고른 초안으로 추가 / 줄마다 그냥 추가 / 취소(null).
sealed class AiPasteOutcome {
  const AiPasteOutcome();
}

class AiPasteDrafts extends AiPasteOutcome {
  const AiPasteDrafts(this.drafts);

  /// 체크된 초안만 (하위도 체크된 것만 남긴 상태).
  final List<AiPasteDraft> drafts;
}

class AiPastePlain extends AiPasteOutcome {
  const AiPastePlain();
}

/// T2 — 붙여넣은 글을 AI 가 정리한 초안. 대표님이 고른 것만 추가한다.
///
/// 데스크탑은 가운데 대화상자(폭 640, 시트와 같은 폭), 폰은 아래에서 올라오는 시트.
class AiPasteDraftPanel extends ConsumerStatefulWidget {
  const AiPasteDraftPanel({
    super.key,
    required this.raw,
    required this.categories,
    required this.defaultCategory,
    required this.childMode,
    required this.calendarOn,
    required this.today,
  });

  final String raw;
  final List<Category> categories;

  /// 시트의 현재 카테고리 — AI 가 모르겠다고 한 항목의 카테고리.
  final Category defaultCategory;

  /// 하위 추가 모드 — 카테고리 칩을 숨긴다(전부 그 부모 아래로).
  final bool childMode;

  /// 날짜 있는 항목이 캘린더에 올라가는지 (미리 📅 로 보여 준다).
  final bool calendarOn;

  final DateTime today;

  static Future<AiPasteOutcome?> show(
    BuildContext context, {
    required String raw,
    required List<Category> categories,
    required Category defaultCategory,
    required bool childMode,
    required bool calendarOn,
    required DateTime today,
  }) {
    final panel = AiPasteDraftPanel(
      raw: raw,
      categories: categories,
      defaultCategory: defaultCategory,
      childMode: childMode,
      calendarOn: calendarOn,
      today: today,
    );
    if (AppPlatform.isMobile) {
      return showModalBottomSheet<AiPasteOutcome>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: panel),
      );
    }
    return showDialog<AiPasteOutcome>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 640,
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: panel,
        ),
      ),
    );
  }

  @override
  ConsumerState<AiPasteDraftPanel> createState() => _AiPasteDraftPanelState();
}

class _AiPasteDraftPanelState extends ConsumerState<AiPasteDraftPanel> {
  List<AiPasteDraft>? _drafts;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final gateway = ref.read(aiGatewayProvider);
    final drafts = gateway == null
        ? null
        : await ref
              .read(aiPasteOrganizerProvider)
              .organize(
                gateway,
                raw: widget.raw,
                categories: widget.categories,
                defaultCategoryId: widget.defaultCategory.id,
                childMode: widget.childMode,
                today: widget.today,
              );
    if (!mounted) return;
    setState(() {
      _drafts = drafts;
      _loading = false;
    });
  }

  int get _count {
    var n = 0;
    for (final d in _drafts ?? const <AiPasteDraft>[]) {
      if (!d.selected) continue;
      n += 1 + d.children.where((c) => c.selected).length;
    }
    return n;
  }

  void _confirm() {
    final picked = [
      for (final d in _drafts!)
        if (d.selected)
          AiPasteDraft(
            title: d.title,
            categoryId: d.categoryId,
            date: d.date,
            timeAnchor: d.timeAnchor,
            evidence: d.evidence,
            children: [
              for (final c in d.children)
                if (c.selected) c,
            ],
          ),
    ];
    Navigator.of(context).pop(AiPasteDrafts(picked));
  }

  Category _categoryOf(AiPasteDraft d) =>
      widget.categories.where((c) => c.id == d.categoryId).firstOrNull ??
      widget.defaultCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drafts = _drafts;
    final Widget body;
    if (_loading) {
      body = const Center(
        key: ValueKey('ai-paste-loading'),
        child: Padding(
          padding: EdgeInsets.all(AppTokens.space24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: AppTokens.space12),
              Text('AI 가 할 일을 정리하고 있어요…'),
            ],
          ),
        ),
      );
    } else if (drafts == null || drafts.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(AppTokens.space16),
        child: AiInlineError(message: drafts == null ? null : '할 일을 찾지 못했어요'),
      );
    } else {
      body = ListView.separated(
        key: const ValueKey('ai-paste-list'),
        padding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
        itemCount: drafts.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _DraftRow(
          index: i,
          draft: drafts[i],
          category: _categoryOf(drafts[i]),
          categories: widget.categories,
          childMode: widget.childMode,
          calendarOn: widget.calendarOn,
          onChanged: () => setState(() {}),
        ),
      );
    }
    final failed = !_loading && (drafts == null || drafts.isEmpty);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.space20,
              AppTokens.space16,
              AppTokens.space20,
              AppTokens.space8,
            ),
            child: Text(
              'AI 로 정리',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const Divider(height: 1),
          Flexible(child: body),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(AppTokens.space12),
            child: Row(
              children: [
                if (failed)
                  TextButton(
                    key: const ValueKey('ai-paste-plain'),
                    onPressed: () =>
                        Navigator.of(context).pop(const AiPastePlain()),
                    child: const Text('줄마다 그냥 추가'),
                  ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('ai-paste-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
                const SizedBox(width: AppTokens.space8),
                FilledButton(
                  key: const ValueKey('ai-paste-confirm'),
                  onPressed: _loading || failed || _count == 0
                      ? null
                      : _confirm,
                  child: Text('$_count건 추가'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({
    required this.index,
    required this.draft,
    required this.category,
    required this.categories,
    required this.childMode,
    required this.calendarOn,
    required this.onChanged,
  });

  final int index;
  final AiPasteDraft draft;
  final Category category;
  final List<Category> categories;
  final bool childMode;
  final bool calendarOn;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final compact = AppPlatform.isMobile;
    final date = draft.date;
    return Padding(
      key: ValueKey('ai-paste-row-$index'),
      padding: EdgeInsets.symmetric(
        horizontal: AppTokens.space8,
        vertical: compact ? AppTokens.space2 : AppTokens.space4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                key: ValueKey('ai-paste-check-$index'),
                value: draft.selected,
                onChanged: (v) {
                  draft.selected = v ?? false;
                  onChanged();
                },
              ),
              Expanded(
                child: Text(
                  draft.title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: draft.selected ? null : muted,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: Wrap(
              spacing: AppTokens.space8,
              runSpacing: AppTokens.space4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!childMode)
                  PopupMenuButton<String>(
                    key: ValueKey('ai-paste-category-$index'),
                    tooltip: '카테고리 바꾸기',
                    onSelected: (id) {
                      draft.categoryId = id;
                      onChanged();
                    },
                    itemBuilder: (_) => [
                      for (final c in categories)
                        PopupMenuItem(value: c.id, child: Text(c.label)),
                    ],
                    child: Chip(
                      avatar: Icon(
                        category.icon,
                        size: 14,
                        color: category.color,
                      ),
                      label: Text(category.label),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (date != null)
                  InputChip(
                    key: ValueKey('ai-paste-date-$index'),
                    avatar: Icon(
                      calendarOn ? Icons.event_available : Icons.event,
                      size: 14,
                    ),
                    label: Text(
                      AiJson.localDate(date.at, allDay: date.allDay) +
                          (draft.timeAnchor == 'end' ? ' 까지' : ''),
                    ),
                    tooltip: calendarOn
                        ? '캘린더에도 올라가요 · ✕ 로 날짜 빼기'
                        : '✕ 로 날짜 빼기',
                    visualDensity: VisualDensity.compact,
                    onDeleted: () {
                      draft.date = null;
                      onChanged();
                    },
                  ),
                if (draft.evidence != null)
                  Text(
                    '“${draft.evidence}”',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
          for (var j = 0; j < draft.children.length; j++)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Row(
                children: [
                  Checkbox(
                    key: ValueKey('ai-paste-child-$index-$j'),
                    value: draft.selected && draft.children[j].selected,
                    onChanged: draft.selected
                        ? (v) {
                            draft.children[j].selected = v ?? false;
                            onChanged();
                          }
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      draft.children[j].title,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
