import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../../domain/policies/stale_backlog_policy.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../ai/ai_providers.dart';
import '../ai/backlog/ai_stale_advisor.dart';
import '../ai/widgets/ai_inline_error.dart';
import '../calendar/calendar_providers.dart';
import '../calendar_view/calendar_drag.dart';
import '../category/categories_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/todo_row_actions.dart';

/// 30일 넘게 남아 있는 미완료 최상위 할 일 — [StaleBacklogPolicy].
final staleBacklogProvider = Provider<List<Todo>>((ref) {
  final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
  final active = ref.watch(activeCategoriesProvider).asData?.value;
  if (active == null) return const [];
  return StaleBacklogPolicy.select(
    all,
    activeCategoryIds: {for (final c in active) c.id},
    now: ref.watch(nowProvider)(),
  );
});

/// "오래된 할 일" 정리 화면 — 한 달 넘게 남은 백로그를 골라 한 번에 완료·날짜 지정·삭제.
///
/// 아무것도 자동으로 바꾸지 않는다. 고른 것만, 누른 동작만, 되돌리기(⌘Z)와 함께.
/// 항목을 누르면 상세(다른 목록과 같은 규칙).
class StaleBacklogScreen extends ConsumerStatefulWidget {
  const StaleBacklogScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const StaleBacklogScreen()));

  @override
  ConsumerState<StaleBacklogScreen> createState() => _StaleBacklogScreenState();
}

class _StaleBacklogScreenState extends ConsumerState<StaleBacklogScreen> {
  final Set<String> _selected = {};

  // ── AI 정리 제안 (T3) — 세션 한정, 영속하지 않는다 ──────────────────────
  /// todo id → 제안. 칩을 적용하면 그 항목의 제안은 지운다.
  final Map<String, AiStaleSuggestion> _suggestions = {};

  /// '유지'·숨기기로 칩을 치운 항목.
  final Set<String> _kept = {};

  /// '완료 추정' 칩을 한 번 눌러 "완료할까요?" 로 바뀐 항목 — 4초 안에 다시 눌러야 완료.
  String? _confirmingDoneId;
  Timer? _confirmTimer;
  bool _aiLoading = false;
  bool _aiFailed = false;
  StreamSubscription<Map<String, AiStaleSuggestion>?>? _aiSub;

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _aiSub?.cancel();
    super.dispose();
  }

  List<Todo> _picked(List<Todo> items) => [
    for (final t in items)
      if (_selected.contains(t.id)) t,
  ];

  /// 고른 항목 선택 해제 — 일괄 동작은 전부, 행 칩은 그 항목만(다른 선택은 유지).
  void _unselect(List<Todo> picked, {required bool all}) {
    if (!mounted) return;
    setState(() {
      all ? _selected.clear() : _selected.removeAll(picked.map((t) => t.id));
    });
  }

  Future<void> _complete(
    List<Todo> picked, {
    bool clearSelection = true,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(todoActionsProvider);
    for (final t in picked) {
      await actions.toggle(t);
    }
    _unselect(picked, all: clearSelection);
    showUndoSnackbarOn(
      messenger,
      message: '${picked.length}개를 완료했어요.',
      onUndo: () async {
        for (final t in picked) {
          await actions.restoreStatus(t);
        }
      },
    );
  }

  Future<void> _schedule(
    List<Todo> picked,
    DateTime day,
    String label, {
    bool clearSelection = true,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(todoActionsProvider);
    final intend = ref.read(calendarIntentProvider);
    for (final t in picked) {
      final moved = applyDateDrop(t, day);
      if (moved == t) continue;
      // 한꺼번에 날짜를 붙이는 정리 동작이다 — 새로 날짜가 생긴 항목을 Google
      // Calendar 에 N개씩 등록하지 않는다(이미 연결된 항목은 평소처럼 일정도 옮긴다).
      if (t.calendarEventId == null) intend(false);
      await actions.updatePreservingOrder(moved);
    }
    _unselect(picked, all: clearSelection);
    showUndoSnackbarOn(
      messenger,
      message: '${picked.length}개를 $label(으)로 옮겼어요.',
      onUndo: () async {
        for (final t in picked) {
          await actions.restoreDates(t);
        }
      },
    );
  }

  Future<void> _delete(List<Todo> picked) async {
    final all = ref.read(allTodosProvider).asData?.value;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${picked.length}개 삭제'),
            content: const Text('하위 항목도 함께 지워져요. 바로 되돌릴 수 있어요.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const ValueKey('stale-confirm-delete'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(todoActionsProvider);
    final snapshot = <Todo>[];
    for (final t in picked) {
      snapshot.addAll(await actions.deleteTree(t, all: all));
    }
    if (mounted) setState(_selected.clear);
    showUndoSnackbarOn(
      messenger,
      message: '${picked.length}개를 삭제했어요.',
      onUndo: () => actions.restoreDeleted(snapshot),
    );
  }

  /// 오늘(로컬 자정).
  DateTime _today() {
    final now = ref.read(nowProvider)();
    return DateTime(now.year, now.month, now.day);
  }

  /// 다음 주 월요일 — Duration 덧셈은 서머타임 경계에서 날짜가 밀릴 수 있어 달력 연산.
  static DateTime _nextMonday(DateTime today) =>
      DateTime(today.year, today.month, today.day + 8 - today.weekday);

  /// 장기 목표 카테고리 — 지워졌거나 보관됐으면 null.
  Category? _longterm() {
    final active = ref.read(activeCategoriesProvider).asData?.value;
    return active?.where((c) => c.id == Category.longterm.id).firstOrNull;
  }

  /// [제안 받기] — 목록 전체를 40건씩 보내고, 오는 대로 행에 칩을 띄운다.
  /// 아무것도 바꾸지 않는다. 칩을 눌러야 기존 정리 동작(되돌리기 포함)이 돈다.
  Future<void> _requestSuggestions(
    List<Todo> items,
    Map<String, int> childCounts,
  ) async {
    if (_aiLoading) return;
    final gateway = ref.read(aiGatewayProvider);
    if (gateway == null) {
      setState(() => _aiFailed = true);
      return;
    }
    await _aiSub?.cancel();
    _confirmTimer?.cancel();
    setState(() {
      _aiLoading = true;
      _aiFailed = false;
      _suggestions.clear();
      _kept.clear();
      _confirmingDoneId = null;
    });
    // 설명 전송 설정은 처음 읽을 때 기본값(켬)부터 내고 저장값을 비동기로 복원한다 —
    // 복원 전에 읽으면 꺼 둔 설정이 무시되어 설명이 나간다.
    await ref.read(aiSendDescriptionProvider.notifier).restored;
    if (!mounted) return;
    var failed = false;
    _aiSub = ref
        .read(aiStaleAdvisorProvider)
        .suggest(
          gateway,
          items,
          now: ref.read(nowProvider)(),
          sendDescription: ref.read(aiSendDescriptionProvider),
          childCounts: childCounts,
          archivedCategoryIds: ref.read(archivedCategoryIdsProvider),
          longtermAvailable: _longterm() != null,
        )
        .listen(
          (batch) {
            if (!mounted) return;
            if (batch == null) {
              failed = true;
              return;
            }
            // 응답을 기다리는 사이 다른 곳에서 완료·날짜 지정된 항목은 건너뛴다.
            final live = {for (final t in ref.read(staleBacklogProvider)) t.id};
            setState(() {
              for (final e in batch.entries) {
                if (live.contains(e.key)) _suggestions[e.key] = e.value;
              }
            });
          },
          onDone: () {
            if (!mounted) return;
            setState(() {
              _aiLoading = false;
              _aiFailed = failed;
            });
          },
        );
  }

  /// 행 칩 — 기존 정리 동작 경로 그대로. 선택해 둔 다른 항목은 건드리지 않는다.
  Future<void> _applySuggestion(Todo t, AiStaleSuggestion s) async {
    switch (s.action) {
      case AiStaleAction.done:
        // 되돌리기가 있어도 '완료' 는 추정이라 두 번 확인한다.
        if (_confirmingDoneId != t.id) {
          _confirmTimer?.cancel();
          setState(() => _confirmingDoneId = t.id);
          _confirmTimer = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _confirmingDoneId = null);
          });
          return;
        }
        _confirmTimer?.cancel();
        setState(() {
          _confirmingDoneId = null;
          _suggestions.remove(t.id);
        });
        await _complete([t], clearSelection: false);
      case AiStaleAction.nextWeek:
        setState(() => _suggestions.remove(t.id));
        await _schedule(
          [t],
          _nextMonday(_today()),
          '다음 주 월요일',
          clearSelection: false,
        );
      case AiStaleAction.nextMonth:
        final today = _today();
        setState(() => _suggestions.remove(t.id));
        await _schedule(
          [t],
          DateTime(today.year, today.month + 1, 1),
          '다음 달 1일',
          clearSelection: false,
        );
      case AiStaleAction.longterm:
        final target = _longterm();
        if (target == null) {
          setState(() => _kept.add(t.id));
          return;
        }
        final moved = await moveTodoWithUndo(
          context,
          ProviderScope.containerOf(context, listen: false),
          item: t,
          category: target,
        );
        if (moved && mounted) setState(() => _suggestions.remove(t.id));
      case AiStaleAction.keep:
        setState(() => _kept.add(t.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = ref.watch(staleBacklogProvider);
    final aiReady = ref.watch(aiReadinessProvider).isReady;
    final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
    final now = ref.watch(nowProvider)();
    // 목록에서 사라진(다른 곳에서 완료·삭제된) 항목은 선택에서도 뺀다.
    _selected.retainAll({for (final t in items) t.id});
    final picked = _picked(items);
    final allSelected = items.isNotEmpty && picked.length == items.length;

    final childCounts = <String, int>{};
    for (final t in all) {
      final pid = t.parentId;
      if (pid != null) childCounts[pid] = (childCounts[pid] ?? 0) + 1;
    }

    final today = DateTime(now.year, now.month, now.day);
    final nextMonday = _nextMonday(today);

    return Scaffold(
      appBar: AppBar(
        title: const Text('오래된 할 일'),
        actions: [
          if (aiReady && items.isNotEmpty)
            _SuggestButton(
              loading: _aiLoading,
              onPressed: () => _requestSuggestions(items, childCounts),
            ),
          if (items.isNotEmpty)
            TextButton(
              key: const ValueKey('stale-select-all'),
              onPressed: () => setState(() {
                allSelected
                    ? _selected.clear()
                    : _selected.addAll(items.map((t) => t.id));
              }),
              child: Text(allSelected ? '선택 해제' : '모두 선택'),
            ),
        ],
      ),
      body: items.isEmpty
          ? const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: '오래된 할 일이 없어요',
              subtitle: '한 달 넘게 남아 있는 할 일이 생기면 여기에 모여요.',
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space8,
                    AppTokens.space8,
                    AppTokens.space8,
                    AppTokens.space48,
                  ),
                  itemCount: items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppTokens.space12,
                          AppTokens.space4,
                          AppTokens.space12,
                          AppTokens.space12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '만든 지 ${StaleBacklogPolicy.defaultDays}일 넘은 미완료 '
                              '${items.length}개 · 오래된 순. 골라서 한 번에 정리하세요.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (_aiLoading)
                              const _AiLoadingLine()
                            else if (_aiFailed)
                              const AiInlineError(),
                          ],
                        ),
                      );
                    }
                    final t = items[i - 1];
                    final suggestion = _kept.contains(t.id)
                        ? null
                        : _suggestions[t.id];
                    return _StaleRow(
                      todo: t,
                      age: StaleBacklogPolicy.ageInDays(t, now),
                      childCount: childCounts[t.id] ?? 0,
                      selected: _selected.contains(t.id),
                      onSelected: (v) => setState(() {
                        v ? _selected.add(t.id) : _selected.remove(t.id);
                      }),
                      onOpen: () => openTodoDetail(context, t),
                      suggestion: suggestion,
                      confirmingDone: _confirmingDoneId == t.id,
                      onApply: suggestion == null
                          ? null
                          : () => _applySuggestion(t, suggestion),
                      onDismiss: () => setState(() => _kept.add(t.id)),
                    );
                  },
                ),
              ),
            ),
      bottomNavigationBar: picked.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppTokens.space12),
                child: Wrap(
                  key: const ValueKey('stale-action-bar'),
                  alignment: WrapAlignment.center,
                  spacing: AppTokens.space8,
                  runSpacing: AppTokens.space8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('stale-complete'),
                      onPressed: () => _complete(picked),
                      icon: const Icon(Icons.check, size: 18),
                      label: Text('완료 ${picked.length}'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('stale-today'),
                      onPressed: () => _schedule(picked, today, '오늘'),
                      child: const Text('오늘로'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('stale-next-week'),
                      onPressed: () =>
                          _schedule(picked, nextMonday, '다음 주 월요일'),
                      child: const Text('다음 주 월'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('stale-delete'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: () => _delete(picked),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('삭제'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _StaleRow extends StatelessWidget {
  const _StaleRow({
    required this.todo,
    required this.age,
    required this.childCount,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
    this.suggestion,
    this.confirmingDone = false,
    this.onApply,
    this.onDismiss,
  });

  final Todo todo;
  final int age;
  final int childCount;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;

  /// AI 정리 제안 — 없으면 칩 줄을 그리지 않는다.
  final AiStaleSuggestion? suggestion;

  /// '완료 추정' 을 한 번 눌러 확인을 기다리는 중.
  final bool confirmingDone;
  final VoidCallback? onApply;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final meta = [
      todo.category.label,
      '$age일 전',
      if (childCount > 0) '하위 $childCount',
    ].join(' · ');
    return Material(
      key: ValueKey('stale-row-${todo.id}'),
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTokens.radiusM),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.space4),
          child: Row(
            children: [
              Checkbox(
                key: ValueKey('stale-select-${todo.id}'),
                value: selected,
                onChanged: (v) => onSelected(v ?? false),
              ),
              Icon(todo.category.icon, size: 18, color: todo.category.color),
              const SizedBox(width: AppTokens.space8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      todo.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                    if (suggestion case final s?)
                      _SuggestionLine(
                        todoId: todo.id,
                        suggestion: s,
                        confirmingDone: confirmingDone,
                        onApply: onApply,
                        onDismiss: onDismiss,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppTokens.space8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 앱바 [제안 받기] — 데스크탑은 글자 버튼, 폰은 아이콘(밀도만 다르고 기능은 같다).
class _SuggestButton extends StatelessWidget {
  const _SuggestButton({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const key = ValueKey('stale-ai-suggest');
    final onTap = loading ? null : onPressed;
    if (AppPlatform.isMobile) {
      return IconButton(
        key: key,
        tooltip: '정리 제안 받기',
        onPressed: onTap,
        icon: const Icon(Icons.auto_awesome),
      );
    }
    return TextButton.icon(
      key: key,
      onPressed: onTap,
      icon: const Icon(Icons.auto_awesome, size: 18),
      label: const Text('제안 받기'),
    );
  }
}

class _AiLoadingLine extends StatelessWidget {
  const _AiLoadingLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('stale-ai-loading'),
      padding: const EdgeInsets.only(top: AppTokens.space8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppTokens.space8),
          Text(
            '정리 제안을 받는 중…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 행 아래 제안 한 줄 — 칩 1개 + 근거. 폰은 근거를 칩 아래 줄로 내린다(폭).
class _SuggestionLine extends StatelessWidget {
  const _SuggestionLine({
    required this.todoId,
    required this.suggestion,
    required this.confirmingDone,
    required this.onApply,
    required this.onDismiss,
  });

  final String todoId;
  final AiStaleSuggestion suggestion;
  final bool confirmingDone;
  final VoidCallback? onApply;
  final VoidCallback? onDismiss;

  static String _label(AiStaleAction a, {required bool confirming}) =>
      switch (a) {
        AiStaleAction.done => confirming ? '완료할까요?' : '완료 추정',
        AiStaleAction.nextWeek => '다음 주',
        AiStaleAction.nextMonth => '다음 달',
        AiStaleAction.longterm => '장기 목표로',
        AiStaleAction.keep => '유지',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mobile = AppPlatform.isMobile;
    final confirming =
        confirmingDone && suggestion.action == AiStaleAction.done;
    final chip = ActionChip(
      key: ValueKey('stale-ai-chip-$todoId'),
      avatar: Icon(
        confirming ? Icons.check : Icons.auto_awesome,
        size: 16,
        color: confirming ? scheme.onPrimary : scheme.primary,
      ),
      label: Text(_label(suggestion.action, confirming: confirming)),
      labelStyle: confirming ? TextStyle(color: scheme.onPrimary) : null,
      backgroundColor: confirming ? scheme.primary : null,
      visualDensity: VisualDensity.compact,
      tooltip: suggestion.action == AiStaleAction.keep ? '제안 숨기기' : null,
      onPressed: onApply,
    );
    final reason = suggestion.reason.isEmpty
        ? null
        : Text(
            suggestion.reason,
            key: ValueKey('stale-ai-reason-$todoId'),
            maxLines: mobile ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          );
    // '유지' 는 칩 자체가 숨기기라 따로 닫기 버튼을 두지 않는다.
    final dismiss = suggestion.action == AiStaleAction.keep
        ? null
        : IconButton(
            key: ValueKey('stale-ai-dismiss-$todoId'),
            tooltip: '제안 숨기기',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
          );
    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.space4),
      child: mobile
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [chip, ?dismiss]),
                ?reason,
              ],
            )
          : Row(
              children: [
                chip,
                const SizedBox(width: AppTokens.space8),
                if (reason != null) Flexible(child: reason),
                ?dismiss,
              ],
            ),
    );
  }
}
