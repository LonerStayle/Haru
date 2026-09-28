import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_format.dart';
import '../../core/theme.dart';
import '../../domain/group.dart';
import '../../domain/policies/description_checklist.dart';
import '../../domain/recurrence.dart';
import '../../domain/todo.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/skeleton.dart';
import '../../ui/widgets/sort_mode_button.dart';
import '../../ui/widgets/todo_action_menu.dart';
import '../../ui/widgets/todo_drill_list.dart';
import '../../ui/widgets/todo_status_check.dart';
import '../../ui/widgets/todo_status_filter.dart';
import '../../ui/widgets/undo_snackbar.dart';
import '../add_todo/add_todo_controller.dart';
import '../category/groups_controller.dart';
import '../move_todo/move_todo_sheet.dart';
import '../outline/tree_providers.dart';
import '../recurrence/monthly_repeat_suggestion.dart';
import '../recurrence/recurrence_actions.dart';
import '../settings/sort_mode_controller.dart';
import '../todo_actions/todo_actions_controller.dart';
import '../todo_actions/todo_row_actions.dart';
import '../todo_actions/toggle_with_undo.dart';

/// 할 일 상세 화면 — 목록에서 항목을 탭하면 (하위 유무와 무관하게) 여기로 온다.
///
/// UX 개선 Phase 2:
/// - 위쪽 **부모 카드**: 상태 체크 · 제목(눌러서 바로 고침) · 설명(눌러서 바로 고침) ·
///   일정 · 반복 · 카테고리 경로 · 진행중. 일정·반복 등 나머지는 "편집" 으로 시트.
/// - 앱바 ⋮: 진행중 · 편집 · 이동 · 복사 · 반복 중지 · 삭제(하위 포함, 되돌리기).
/// - 아래 **하위 항목**: 머리에 정렬(전역 설정)·하위 추가, 진척 막대, 상태 칩, 목록.
/// - 다른 곳(다른 기기 등)에서 지워지면 자동으로 닫고 스낵바로 알린다.
///
/// 본문은 [TodoDetailView] — 데스크탑 인스펙터 패널도 같은 위젯을 쓴다.
class TodoDetailScreen extends ConsumerStatefulWidget {
  const TodoDetailScreen({super.key, required this.parent});

  /// 진입 시점의 스냅샷. 최신 상태는 [allTodosProvider] 에서 id 로 재조회.
  final Todo parent;

  @override
  ConsumerState<TodoDetailScreen> createState() => _TodoDetailScreenState();
}

class _TodoDetailScreenState extends ConsumerState<TodoDetailScreen> {
  /// ⋮ 삭제로 직접 지운 중 — "다른 곳에서 삭제" 알림을 띄우지 않는다.
  bool _deleting = false;

  /// 이 화면이 아직 맨 위일 때만 닫는다. 이미 닫히는 중(삭제 직후 애니메이션)에
  /// 삭제 알림이 도착해도 아래 화면을 잘못 닫지 않게.
  void _closeIfCurrent() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop();
    }
  }

  /// 다른 곳에서 지워졌을 때 — 맨 위면 닫고, 위에 다른 화면(하위 상세·시트)이 있으면
  /// 스택에서 조용히 뺀다. 지워진 항목의 상세가 뒤에 남아 있다가 고치면 되살아난다.
  void _removeSelf() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parent;
    final allTodos = ref.watch(allTodosProvider).asData?.value;
    final live =
        allTodos?.firstWhere((t) => t.id == parent.id, orElse: () => parent) ??
        parent;
    return Scaffold(
      appBar: AppBar(
        title: Text(live.title, overflow: TextOverflow.ellipsis),
        actions: [
          TodoDetailMenuButton(
            todo: live,
            onDeleted: () {
              setState(() => _deleting = true);
              _closeIfCurrent();
            },
          ),
        ],
      ),
      body: TodoDetailView(
        parent: parent,
        suppressGoneNotice: _deleting,
        onGone: _deleting ? _closeIfCurrent : _removeSelf,
      ),
    );
  }
}

/// 상세 ⋮ 메뉴 — 목록 행 메뉴와 같은 항목([TodoMenu]).
///
/// 삭제는 하위 항목까지 지우고 되돌리기를 띄운 뒤 [onDeleted] (화면 닫기 등).
class TodoDetailMenuButton extends ConsumerWidget {
  const TodoDetailMenuButton({
    super.key,
    required this.todo,
    required this.onDeleted,
  });

  final Todo todo;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(todoActionsProvider);
    final isTask = todo.type == TodoType.task;
    final menu = TodoMenu(
      todo: todo,
      onToggleInProgress: isTask ? () => actions.toggleInProgress(todo) : null,
      onEdit: () => openTodoEdit(context, ref, todo),
      onMove: () => showMoveTodoSheet(context, ref, item: todo),
      onCopy: () => showCopyTodoSheet(context, ref, original: todo),
      onStopRecurrence: () => confirmStopRecurrence(context, ref, todo),
      onDelete: () {
        // 지우기 전에 ref·messenger 를 잡는다(deleteTodoWithUndo 가 첫 줄에서 읽음) →
        // 그다음 화면을 닫는다.
        deleteTodoWithUndo(context, ref, todo);
        onDeleted();
      },
    );
    return PopupMenuButton<TodoMenuAction>(
      key: const ValueKey('detail-menu'),
      tooltip: '메뉴',
      icon: const Icon(Icons.more_vert),
      itemBuilder: (ctx) =>
          menu.popupItems(ctx, menu.actions(includeQuick: true)),
      onSelected: menu.run,
    );
  }
}

/// 상세 본문 — 부모 카드 + 하위 항목. Scaffold 없이 어디든 끼워 쓸 수 있다.
class TodoDetailView extends ConsumerStatefulWidget {
  const TodoDetailView({
    super.key,
    required this.parent,
    required this.onGone,
    this.onOpenTodo,
    this.suppressGoneNotice = false,
  });

  /// 진입 시점의 스냅샷. 최신 상태는 [allTodosProvider] 에서 id 로 재조회.
  final Todo parent;

  /// 이 항목이 (다른 곳에서) 지워졌을 때 — 화면 닫기 등. 알림 스낵바는 여기서 띄운다.
  final VoidCallback onGone;

  /// 하위 항목 탭 — 기본은 새 상세 화면 push.
  final void Function(Todo todo)? onOpenTodo;

  /// 이 화면에서 직접 지우는 중 — 자동 닫힘 알림("다른 곳에서 삭제")을 띄우지 않는다.
  final bool suppressGoneNotice;

  @override
  ConsumerState<TodoDetailView> createState() => _TodoDetailViewState();
}

class _TodoDetailViewState extends ConsumerState<TodoDetailView> {
  /// 상태별 보기 — 선택된 칩. 화면을 벗어나면 '전체'로 초기화된다.
  TodoStatusFilter _filter = TodoStatusFilter.all;

  bool _goneHandled = false;

  @override
  void didUpdateWidget(TodoDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 인스펙터처럼 같은 자리에서 다른 항목으로 바뀌면 화면 상태를 새로.
    if (oldWidget.parent.id != widget.parent.id) {
      _goneHandled = false;
      _filter = TodoStatusFilter.all;
    }
  }

  void _handleGone(Todo last) {
    if (_goneHandled) return;
    _goneHandled = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final self = widget.suppressGoneNotice;
      widget.onGone();
      if (!self && messenger != null && messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('"${last.title}" 항목이 다른 곳에서 삭제돼 닫았어요.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  /// 전환 중 — 더블클릭으로 하위가 두 벌 생기지 않게.
  bool _converting = false;

  /// 설명 속 목록을 하위 항목으로 옮긴다 — 되돌리기 스낵바(⌘Z)로 원래대로.
  Future<void> _checklistToChildren(
    Todo live,
    DescriptionChecklist checklist,
  ) async {
    if (_converting) return;
    _converting = true;
    try {
      await _convert(live, checklist);
    } finally {
      _converting = false;
    }
  }

  Future<void> _convert(Todo live, DescriptionChecklist checklist) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final actions = ref.read(todoActionsProvider);
    final result = await actions.checklistToChildren(
      live,
      items: [for (final i in checklist.items) (title: i.title, done: i.done)],
      remainingDescription: checklist.remaining,
    );
    if (messenger == null || !messenger.mounted) return;
    showUndoSnackbarOn(
      messenger,
      message: '설명 목록 ${result.created.length}개를 하위 항목으로 옮겼어요.',
      onUndo: () => actions.undoChecklist(result.created, result.parentBefore),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parent;
    final asyncAll = ref.watch(allTodosProvider);
    final asyncChildren = ref.watch(childrenOfProvider(parent.id));
    // 카테고리 화면의 정렬 버튼과 같은 전역 상태 — 하위 목록도 함께 일정순으로 보인다.
    final sortMode = ref.watch(sortModeProvider);
    final groups =
        ref.watch(activeGroupsProvider).asData?.value ?? const <Group>[];

    final allTodos = asyncAll.asData?.value ?? const <Todo>[];
    final live = allTodos.firstWhere(
      (t) => t.id == parent.id,
      orElse: () => parent,
    );
    final gone = asyncAll.hasValue && !allTodos.any((t) => t.id == parent.id);
    if (gone) _handleGone(live);

    final actions = ref.read(todoActionsProvider);
    final openTodo =
        widget.onOpenTodo ?? (Todo t) => openTodoDetail(context, t);
    final accent = live.category.color;

    final card = SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space12,
        AppTokens.space16,
        AppTokens.space8,
      ),
      sliver: SliverToBoxAdapter(
        child: _ParentCard(
          todo: live,
          allTodos: allTodos,
          groups: groups,
          // 지워진 항목(스냅샷만 남음)에 쓰면 되살아난다 — 전부 막는다.
          onToggle: gone ? null : () => toggleWithUndo(context, actions, live),
          onToggleInProgress: gone
              ? null
              : () => actions.toggleInProgress(live),
          onRename: gone
              ? null
              : (title) => actions.update(live.copyWith(title: title)),
          onDescribe: gone
              ? null
              : (text) => actions.update(
                  live.copyWith(description: text.isEmpty ? null : text),
                ),
          onEdit: gone ? null : () => openTodoEdit(context, ref, live),
          onMove: gone
              ? null
              : () => showMoveTodoSheet(context, ref, item: live),
        ),
      ),
    );
    // 매달 손으로 만드는 항목이면 "매월 반복 만들기" 제안.
    final monthly = SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.space16),
      sliver: SliverToBoxAdapter(
        child: gone
            ? const SizedBox.shrink()
            : MonthlyRepeatSuggestionCard(todo: live),
      ),
    );

    return asyncChildren.when(
      loading: () => const TodoListSkeleton(),
      error: (e, _) => ErrorState(
        title: '하위 항목을 불러오지 못했어요',
        error: e,
        onRetry: () => ref.invalidate(childrenOfProvider(widget.parent.id)),
      ),
      data: (children) {
        // 상태별 보기 — 이 항목의 모든 자손이 카운트·필터 대상 (직속 자식만이 아니라).
        final descendants = _descendantsOf(live.id, allTodos);
        final progress = computeSubtreeProgress(live, allTodos);
        void addChild() => showAddChildSheet(context, ref, parent: live);
        // 목록이 한 줄뿐이면 메모일 가능성이 커서 제안하지 않는다.
        final checklist = DescriptionChecklist.parse(live.description);
        return CustomScrollView(
          slivers: [
            card,
            monthly,
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.space16,
                AppTokens.space8,
                AppTokens.space8,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: _ChildrenHeader(
                  count: descendants.length,
                  sortButton: children.isEmpty
                      ? null
                      : SortModeIconButton(
                          mode: sortMode,
                          accent: accent,
                          onPressed: () =>
                              ref.read(sortModeProvider.notifier).toggle(),
                        ),
                  onAddChild: addChild,
                ),
              ),
            ),
            if (!gone && checklist.items.length >= 2)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space16,
                  AppTokens.space8,
                  AppTokens.space16,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: _ChecklistSuggestion(
                    count: checklist.items.length,
                    accent: accent,
                    onConvert: () => _checklistToChildren(live, checklist),
                  ),
                ),
              ),
            if (children.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(AppTokens.space16),
                sliver: SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.checklist_rounded,
                    tone: accent,
                    title: '하위 항목이 없어요',
                    subtitle: live.type == TodoType.note
                        ? '이 메모 아래에 항목을 나눠 적을 수 있어요.'
                        : '잘게 나눠 하나씩 체크해 보세요.',
                    action: FilledButton.tonalIcon(
                      key: const ValueKey('detail-empty-add'),
                      onPressed: addChild,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('하위 추가'),
                    ),
                  ),
                ),
              )
            else ...[
              if (progress.taskCount > 0)
                SliverToBoxAdapter(
                  child: _SubtreeProgressBar(
                    progress: progress,
                    accent: accent,
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space16,
                  AppTokens.space12,
                  AppTokens.space16,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: TodoStatusFilterBar(
                    counts: TodoStatusCounts.of(descendants),
                    selected: _filter,
                    onSelected: (f) => setState(() => _filter = f),
                    accent: accent,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space16,
                  AppTokens.space16,
                  AppTokens.space16,
                  AppTokens.space48,
                ),
                sliver: TodoDrillListSliver(
                  items: children,
                  allTodos: allTodos,
                  filter: _filter,
                  filterPool: descendants,
                  // 이 화면의 부모는 이미 카드 제목 — 경로에서 제외.
                  breadcrumbRootId: live.id,
                  onDrillDown: openTodo,
                  onEdit: (t) => openTodoEdit(context, ref, t),
                  onToggle: (t) => toggleWithUndo(context, actions, t),
                  onToggleInProgress: actions.toggleInProgress,
                  onAddChild: (p) => showAddChildSheet(context, ref, parent: p),
                  onMove: (t) => showMoveTodoSheet(context, ref, item: t),
                  onCopy: (t) => showCopyTodoSheet(context, ref, original: t),
                  onDelete: (t) => deleteTodoWithUndo(context, ref, t),
                  onReorderSiblings: actions.reorderSiblings,
                  onStopRecurrence: (t) =>
                      confirmStopRecurrence(context, ref, t),
                  sortMode: sortMode,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 부모 카드 — 이 항목 자체의 모든 정보와 상태 조작.
class _ParentCard extends StatelessWidget {
  const _ParentCard({
    required this.todo,
    required this.allTodos,
    required this.groups,
    required this.onToggle,
    required this.onToggleInProgress,
    required this.onRename,
    required this.onDescribe,
    required this.onEdit,
    required this.onMove,
  });

  final Todo todo;
  final List<Todo> allTodos;
  final List<Group> groups;
  final VoidCallback? onToggle;
  final VoidCallback? onToggleInProgress;
  final ValueChanged<String>? onRename;
  final ValueChanged<String>? onDescribe;
  final VoidCallback? onEdit;
  final VoidCallback? onMove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = todo.category.color;
    final isTask = todo.type == TodoType.task;

    // 카테고리 경로 — 그룹 › 카테고리.
    String? groupLabel;
    for (final g in groups) {
      if (g.id == todo.category.groupId) groupLabel = g.label;
    }
    final categoryPath = groupLabel == null
        ? todo.category.label
        : '$groupLabel › ${todo.category.label}';
    // 상위 항목 경로 (하위 항목일 때).
    final parents = computeTodoPath(todo, allTodos);
    final schedule = TodoDateLabel.format(todo);
    final recurrence = _recurrenceLabel(todo, allTodos);

    return DecoratedBox(
      key: const ValueKey('detail-parent-card'),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTokens.radiusL),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.space12,
          AppTokens.space12,
          AppTokens.space12,
          AppTokens.space8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parents.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppTokens.space4,
                  bottom: AppTokens.space4,
                ),
                child: Text(
                  parents.map((p) => p.title).join(' › '),
                  key: const ValueKey('detail-parent-path'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isTask)
                  IconButton(
                    key: const ValueKey('detail-toggle'),
                    tooltip: todo.isDone ? '완료 취소' : '완료',
                    onPressed: onToggle,
                    icon: TodoStatusCheck(
                      status: todo.status,
                      color: accent,
                      size: 26,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(AppTokens.space12),
                    child: Icon(
                      Icons.sticky_note_2_outlined,
                      size: 22,
                      color: accent,
                    ),
                  ),
                Expanded(
                  child: _InlineText(
                    key: ValueKey('detail-title-${todo.id}'),
                    fieldKey: const ValueKey('detail-title-field'),
                    value: todo.title,
                    placeholder: '제목',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      decoration: todo.isDone
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                    allowEmpty: false,
                    onSave: onRename,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 48),
              child: _InlineText(
                key: ValueKey('detail-description-${todo.id}'),
                fieldKey: const ValueKey('detail-description-field'),
                value: todo.description ?? '',
                placeholder: '설명 추가',
                style: theme.textTheme.bodyMedium,
                multiline: true,
                allowEmpty: true,
                onSave: onDescribe,
              ),
            ),
            const SizedBox(height: AppTokens.space8),
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Wrap(
                spacing: AppTokens.space8,
                runSpacing: AppTokens.space8,
                children: [
                  _MetaChip(
                    key: const ValueKey('detail-meta-category'),
                    icon: todo.category.icon,
                    color: accent,
                    label: categoryPath,
                    tooltip: '다른 카테고리로 이동',
                    onTap: onMove,
                  ),
                  _MetaChip(
                    key: const ValueKey('detail-meta-schedule'),
                    icon: Icons.event_outlined,
                    label: schedule ?? '날짜 없음',
                    muted: schedule == null,
                    tooltip: '일정 편집',
                    onTap: onEdit,
                  ),
                  if (recurrence != null)
                    _MetaChip(
                      key: const ValueKey('detail-meta-recurrence'),
                      icon: Icons.repeat_rounded,
                      label: recurrence,
                      tooltip: '반복 편집',
                      onTap: onEdit,
                    ),
                  if (isTask)
                    _MetaChip(
                      key: const ValueKey('detail-in-progress'),
                      icon: Icons.timelapse_rounded,
                      label: todo.isInProgress ? '진행중' : '진행중으로',
                      color: todo.isInProgress ? accent : null,
                      selected: todo.isInProgress,
                      muted: !todo.isInProgress,
                      tooltip: todo.isInProgress ? '진행중 해제' : '진행중으로 표시',
                      onTap: onToggleInProgress,
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('detail-edit'),
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('전체 편집'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 반복 요약 — 인스턴스는 시리즈 마스터의 규칙을 읽는다.
  static String? _recurrenceLabel(Todo todo, List<Todo> all) {
    final sid = todo.seriesId;
    if (sid == null) return null;
    Todo? master;
    for (final t in all) {
      if (t.id == sid) {
        master = t;
        break;
      }
    }
    final rule = (master ?? todo).recurrenceRule;
    if (rule == null) return '반복';
    try {
      return RecurrenceRule.decode(
        rule,
      ).describe(until: (master ?? todo).recurrenceEndAt?.toLocal());
    } catch (_) {
      return '반복';
    }
  }
}

/// 눌러서 바로 고치는 글자 — 평소엔 글자, 누르면 입력칸. Enter(제목)·Esc·바깥 탭·
/// 포커스 이탈 = 저장. 바뀐 게 없으면 저장하지 않는다(열람만으로 순서가 바뀌지 않게).
class _InlineText extends StatefulWidget {
  const _InlineText({
    super.key,
    required this.fieldKey,
    required this.value,
    required this.placeholder,
    required this.style,
    required this.onSave,
    required this.allowEmpty,
    this.multiline = false,
  });

  final Key fieldKey;
  final String value;
  final String placeholder;
  final TextStyle? style;

  /// null 이면 고칠 수 없다(글자만).
  final ValueChanged<String>? onSave;
  final bool allowEmpty;
  final bool multiline;

  @override
  State<_InlineText> createState() => _InlineTextState();
}

class _InlineTextState extends State<_InlineText> {
  bool _editing = false;
  late final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _ctrl.text = widget.value;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _commit() {
    if (!_editing) return;
    // 편집 시트와 같은 정규화(trim) — 앞뒤 공백만 다른 값은 "바뀐 것" 이 아니다.
    // 안 그러면 열었다 닫기만 해도 저장·맨 위로 올라가기가 일어난다.
    final next = _ctrl.text.trim();
    setState(() => _editing = false);
    if (next == widget.value.trim()) return;
    if (next.isEmpty && !widget.allowEmpty) return;
    widget.onSave?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_editing) {
      return CallbackShortcuts(
        // Esc = 저장하고 닫기 — 앱 전체의 "닫힘 = 저장" 규칙과 같다(쓴 글을 잃지 않게).
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _focus.unfocus,
        },
        child: TextField(
          key: widget.fieldKey,
          controller: _ctrl,
          focusNode: _focus,
          style: widget.style,
          minLines: 1,
          maxLines: widget.multiline ? 8 : 3,
          keyboardType: widget.multiline
              ? TextInputType.multiline
              : TextInputType.text,
          textInputAction: widget.multiline
              ? TextInputAction.newline
              : TextInputAction.done,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.placeholder,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: widget.multiline ? null : (_) => _commit(),
          onTapOutside: (_) => _focus.unfocus(),
        ),
      );
    }
    final empty = widget.value.isEmpty;
    return Semantics(
      button: true,
      label: empty ? widget.placeholder : '${widget.value}, 눌러서 고치기',
      child: InkWell(
        onTap: widget.onSave == null ? null : _start,
        borderRadius: BorderRadius.circular(AppTokens.radiusS),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.space4,
            vertical: AppTokens.space8,
          ),
          child: SizedBox(
            width: double.infinity,
            child: Text(
              empty ? widget.placeholder : widget.value,
              style: empty
                  ? widget.style?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    )
                  : widget.style,
            ),
          ),
        ),
      ),
    );
  }
}

/// 부모 카드의 메타 칩 (카테고리 · 일정 · 반복 · 진행중).
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.muted = false,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final bool muted;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = muted
        ? scheme.onSurface.withValues(alpha: 0.6)
        : scheme.onSurface.withValues(alpha: 0.85);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? (color ?? scheme.primary).withValues(alpha: 0.16)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
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
                  Icon(icon, size: 16, color: color ?? fg),
                  const SizedBox(width: AppTokens.space4),
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(color: fg),
                      overflow: TextOverflow.ellipsis,
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

/// "설명에 목록 N개가 있어요 → 하위 항목으로" 제안 줄. 누르기 전엔 아무것도 바꾸지 않는다.
class _ChecklistSuggestion extends StatelessWidget {
  const _ChecklistSuggestion({
    required this.count,
    required this.accent,
    required this.onConvert,
  });

  final int count;
  final Color accent;
  final VoidCallback onConvert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('detail-checklist-suggestion'),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space12,
        AppTokens.space4,
        AppTokens.space4,
        AppTokens.space4,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
      ),
      child: Row(
        children: [
          Icon(Icons.format_list_bulleted_rounded, size: 18, color: accent),
          const SizedBox(width: AppTokens.space8),
          Expanded(
            child: Text(
              '설명에 목록 $count개가 있어요',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(
            key: const ValueKey('detail-checklist-convert'),
            onPressed: onConvert,
            child: const Text('하위 항목으로'),
          ),
        ],
      ),
    );
  }
}

/// "하위 항목 N" 머리 — 정렬(전역 설정) + 하위 추가.
class _ChildrenHeader extends StatelessWidget {
  const _ChildrenHeader({
    required this.count,
    required this.sortButton,
    required this.onAddChild,
  });

  final int count;
  final Widget? sortButton;
  final VoidCallback onAddChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          count > 0 ? '하위 항목 $count' : '하위 항목',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        ?sortButton,
        TextButton.icon(
          key: const ValueKey('detail-add-child'),
          onPressed: onAddChild,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('하위 추가'),
        ),
      ],
    );
  }
}

/// [rootId] 의 모든 자손을 트리 순서(깊이 우선, 형제는 입력 순서)로 평탄화한다.
///
/// 상태별 보기의 필터 대상 pool + 칩 카운트에 쓴다 — 직속 자식만 세면 "완료 5" 를
/// 눌렀을 때 더 깊은 곳의 완료가 빠져 카운트와 목록이 어긋난다.
/// dangling parentId / 사이클은 방문 집합으로 차단한다.
List<Todo> _descendantsOf(String rootId, List<Todo> all) {
  final byParent = <String, List<Todo>>{};
  for (final t in all) {
    final pid = t.parentId;
    if (pid == null) continue;
    (byParent[pid] ??= []).add(t);
  }
  final result = <Todo>[];
  final visited = <String>{rootId};
  void walk(String parentId) {
    for (final child in byParent[parentId] ?? const <Todo>[]) {
      if (!visited.add(child.id)) continue;
      result.add(child);
      walk(child.id);
    }
  }

  walk(rootId);
  return result;
}

/// 자손 task 진척 요약. `done/total 완료` + 진행 바.
class _SubtreeProgressBar extends StatelessWidget {
  const _SubtreeProgressBar({required this.progress, required this.accent});

  final SubtreeProgress progress;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const ValueKey('detail-progress'),
      padding: const EdgeInsets.fromLTRB(
        AppTokens.space16,
        AppTokens.space8,
        AppTokens.space16,
        0,
      ),
      child: Row(
        children: [
          Text(
            '${progress.doneCount}/${progress.taskCount} 완료',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(width: AppTokens.space12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.radiusFull),
              child: LinearProgressIndicator(
                value: progress.ratio ?? 0,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
