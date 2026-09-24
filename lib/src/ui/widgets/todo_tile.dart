import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/todo.dart';
import 'in_progress_triangle.dart';
import 'todo_status_check.dart';

/// 모바일 압축 모드의 버튼 터치 타겟.
///
/// 기본 [IconButton] 은 48dp 를 먹어 좁은 폰 폭에서 제목이 쓸 폭이 줄어든다.
/// 36dp 는 손가락으로 누르기엔 여전히 충분하다.
/// (IconButton 의 `constraints` 만으로는 부족하다 — Material 3 는 그와 별개로
/// 48dp tap target 패딩을 덧대므로 `tapTargetSize.shrinkWrap` 까지 필요하다.)
const ButtonStyle _kCompactIconButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(36, 36)),
  fixedSize: WidgetStatePropertyAll(Size(36, 36)),
  maximumSize: WidgetStatePropertyAll(Size(36, 36)),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 할 일 한 줄 — 컬러바 + **체크 하나** + 제목 + 메타 한 줄 (UX Phase 1).
///
/// 대표님 결정 (2026-09-25) "체크 하나 + 나머지 숨김":
///  - 보이는 조작은 왼쪽 체크(○/◐/●) 하나. 탭 = 완료 토글.
///  - 진행중(△)·하위 추가(↳)·더보기(⋮)는 데스크탑에서 **마우스를 올렸을 때만** 보이고,
///    **우클릭** 하면 같은 메뉴가 커서 위치에 뜬다.
///  - 폰은 버튼 없이 **길게 눌렀다 떼면** 메뉴 시트, 누른 채 움직이면 순서 이동
///    (목록의 ReorderableDelayedDragStartListener), 오른쪽 스와이프 = 완료
///    ([DismissibleTodoTile]).
class TodoTile extends StatefulWidget {
  const TodoTile({
    super.key,
    required this.todo,
    this.onToggle,
    this.onToggleInProgress,
    this.onTap,
    this.onAddChild,
    this.onMove,
    this.onCopy,
    this.onEditItem,
    this.onDelete,
    this.isExpanded,
    this.onToggleExpand,
    this.childCount = 0,
    this.drillChildCount,
    this.hiddenSeriesCount = 0,
    this.onStopRecurrence,
    this.breadcrumb,
    this.snippet,
    this.isCarriedOver = false,
  });

  final Todo todo;

  /// 체크(완료 토글). null 이면 체크가 비활성.
  final VoidCallback? onToggle;

  /// 진행중 토글. null 이면 진행중 버튼·메뉴 항목 미표시 (진행중 미지원 화면 / note).
  final VoidCallback? onToggleInProgress;

  final VoidCallback? onTap;

  /// 메뉴 — 이 항목을 다른 위치로 이동 (다른 항목의 하위 / 최상위).
  final VoidCallback? onMove;

  /// 메뉴 — 이 항목을 복사 (제목·내용·카테고리·날짜/종류를 채운 새 항목 시트).
  final VoidCallback? onCopy;

  /// 메뉴 — 이 항목 자체를 편집. (폴더든 leaf 든 그 항목 편집 시트.)
  final VoidCallback? onEditItem;

  /// 메뉴 — 이 항목 삭제.
  final VoidCallback? onDelete;

  /// "하위 추가". null 이면 버튼·메뉴 항목 미표시.
  final VoidCallback? onAddChild;

  /// 접힘/펼침 상태. null 이면 자식이 없어 chevron 미표시. (인라인 트리 전용)
  final bool? isExpanded;

  /// chevron tap 콜백 (펼침/접힘 토글). isExpanded != null 일 때만 의미.
  final VoidCallback? onToggleExpand;

  /// 직속 자식 수. note 가 자식을 가지면 "섹션 헤딩" 으로 강조한다.
  final int childCount;

  /// 드릴다운 모드. non-null 이면 "하위 N" 배지 — 타일 탭이 상세 화면 push 임을 알린다.
  final int? drillChildCount;

  /// 같은 반복 시리즈의 숨겨진 미체크 건수. >0 이면 "밀린 반복 외 N건" 배지.
  final int hiddenSeriesCount;

  /// 메뉴의 '반복 중지'. 반복 시리즈 항목일 때만 노출.
  final VoidCallback? onStopRecurrence;

  /// 평탄해진 목록에서 "이 항목이 어디 소속인지" 알려주는 부모 경로. null = 미표시.
  final String? breadcrumb;

  /// 검색 결과에서 메모 본문의 매칭된 부분 발췌.
  final String? snippet;

  /// 어제 이전 날짜라 오늘로 넘어온 항목 — 메타 줄에 "이월" 표시. (오늘 화면만 배선)
  final bool isCarriedOver;

  /// 이 폭 아래로는 데스크탑에서도 압축 레이아웃을 쓴다 (폰 폭 기준).
  static const double _compactWidth = 420;

  @override
  State<TodoTile> createState() => _TodoTileState();
}

class _TodoTileState extends State<TodoTile> {
  /// 데스크탑 — 마우스가 올라와 있거나 메뉴가 열린 동안 보조 버튼을 보인다.
  bool _hovered = false;

  // ── 폰: 길게 눌렀다 떼면 메뉴 ──────────────────────────────────────────
  // 제스처 경합(순서 이동 드래그 / 스크롤 / 스와이프 / 탭)에 끼어들지 않도록
  // 인식기를 두지 않고 [Listener] 로 원시 포인터만 본다. "오래 눌렀고 거의 안
  // 움직였다" 면 떼는 순간 메뉴를 연다. 움직였다면 드래그·스크롤이 이미 가져갔다.
  int? _pressPointer;
  Offset? _pressOrigin;
  bool _pressMoved = false;

  /// 누른 지 [kLongPressTimeout] 이 지났고 그동안 움직이지 않았다 — 떼면 메뉴.
  bool _longPressArmed = false;
  Timer? _pressTimer;

  /// 누르는 순간의 위젯·Navigator. 순서 이동 목록에서는 길게 누르는 순간 드래그가
  /// 시작되며 **이 줄이 트리에서 빠진다**(드래그 중엔 빈 자리 + 떠 있는 복제본).
  /// 떼는 시점엔 이 State 의 context 가 이미 죽어 있으므로, 메뉴는 누를 때 잡아 둔
  /// Navigator 위에 띄우고 콜백도 그때의 위젯 것을 쓴다.
  TodoTile? _pressWidget;
  NavigatorState? _pressNavigator;

  /// 길게 눌러 메뉴를 연 직후의 탭(떼기)은 편집 시트를 열지 않는다.
  bool _suppressNextTap = false;

  Todo get todo => widget.todo;
  bool get _isNote => todo.type == TodoType.note;

  @override
  void dispose() {
    // 누르고 있는 중에 빠졌다면(= 순서 이동 드래그 시작) 타이머를 살려 둔다 — 떼는
    // 순간 메뉴 판정에 필요하다. 타이머 콜백은 필드만 만지므로 dispose 뒤에도 안전.
    if (_pressPointer == null) _pressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 압축 여부는 플랫폼이 아니라 **실제로 주어진 폭**으로 정한다 — 데스크탑에서
    // 창을 좁혀도 폰과 같은 배치가 맞다.
    return LayoutBuilder(
      builder: (context, constraints) => _buildTile(
        context,
        compact:
            AppPlatform.isMobile ||
            constraints.maxWidth < TodoTile._compactWidth,
      ),
    );
  }

  // ── 메뉴 항목 (우클릭·길게 누르기·⋮ 가 같은 목록을 쓴다) ─────────────────

  static List<_TileMenuAction> _menuActions(
    TodoTile w, {
    required bool includeQuick,
  }) {
    final isNote = w.todo.type == TodoType.note;
    return [
      if (includeQuick && !isNote && w.onToggleInProgress != null)
        _TileMenuAction.inProgress,
      if (includeQuick && w.onAddChild != null) _TileMenuAction.addChild,
      if (w.onEditItem != null) _TileMenuAction.edit,
      if (w.onMove != null) _TileMenuAction.move,
      if (w.onCopy != null) _TileMenuAction.copy,
      if (w.onStopRecurrence != null && w.todo.isInRecurringSeries)
        _TileMenuAction.stopRecurrence,
      if (w.onDelete != null) _TileMenuAction.delete,
    ];
  }

  static void _run(TodoTile w, _TileMenuAction action) {
    switch (action) {
      case _TileMenuAction.inProgress:
        w.onToggleInProgress?.call();
      case _TileMenuAction.addChild:
        w.onAddChild?.call();
      case _TileMenuAction.edit:
        w.onEditItem?.call();
      case _TileMenuAction.move:
        w.onMove?.call();
      case _TileMenuAction.copy:
        w.onCopy?.call();
      case _TileMenuAction.stopRecurrence:
        w.onStopRecurrence?.call();
      case _TileMenuAction.delete:
        w.onDelete?.call();
    }
  }

  static (IconData, String) _describe(TodoTile w, _TileMenuAction a) =>
      switch (a) {
        _TileMenuAction.inProgress => (
          Icons.change_history_rounded,
          w.todo.isInProgress ? '진행중 해제' : '진행중으로',
        ),
        _TileMenuAction.addChild => (
          Icons.subdirectory_arrow_right_rounded,
          '하위 추가',
        ),
        _TileMenuAction.edit => (Icons.edit_outlined, '편집'),
        _TileMenuAction.move => (Icons.drive_file_move_outline, '이동'),
        _TileMenuAction.copy => (Icons.copy_outlined, '복사'),
        _TileMenuAction.stopRecurrence => (Icons.repeat_rounded, '반복 중지'),
        _TileMenuAction.delete => (Icons.delete_outline_rounded, '삭제'),
      };

  static List<PopupMenuEntry<_TileMenuAction>> _popupItems(
    BuildContext context,
    TodoTile w,
    List<_TileMenuAction> actions,
  ) {
    final error = Theme.of(context).colorScheme.error;
    return [
      for (final a in actions)
        PopupMenuItem(
          key: ValueKey('todo-tile-menu-item-${a.name}'),
          value: a,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _describe(w, a).$1,
              size: 18,
              color: a == _TileMenuAction.delete ? error : null,
            ),
            title: Text(
              _describe(w, a).$2,
              style: a == _TileMenuAction.delete
                  ? TextStyle(color: error)
                  : null,
            ),
          ),
        ),
    ];
  }

  /// 데스크탑 우클릭 — 커서 위치에 전체 메뉴.
  Future<void> _openContextMenu(Offset globalPosition) async {
    final w = widget;
    final actions = _menuActions(w, includeQuick: true);
    if (actions.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    setState(() => _hovered = true);
    final picked = await showMenu<_TileMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: _popupItems(context, w, actions),
    );
    if (mounted) setState(() => _hovered = false);
    if (picked != null) _run(w, picked);
  }

  /// 폰 길게 누르기 — 아래에서 올라오는 메뉴 시트. [navigator] 는 누를 때 잡아 둔
  /// 것 (이 State 는 이미 트리에서 빠졌을 수 있다).
  static Future<void> _openMenuSheet(
    NavigatorState navigator,
    TodoTile w,
  ) async {
    final actions = _menuActions(w, includeQuick: true);
    if (actions.isEmpty || !navigator.mounted) return;
    final picked = await showModalBottomSheet<_TileMenuAction>(
      context: navigator.context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final error = theme.colorScheme.error;
        // 항목이 많거나 화면이 낮아도 넘치지 않게 스크롤.
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('todo-tile-menu-sheet'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space24,
                    0,
                    AppTokens.space24,
                    AppTokens.space8,
                  ),
                  child: Text(
                    w.todo.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (final a in actions)
                  ListTile(
                    key: ValueKey('todo-tile-sheet-${a.name}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppTokens.space24,
                    ),
                    leading: Icon(
                      _describe(w, a).$1,
                      color: a == _TileMenuAction.delete ? error : null,
                    ),
                    title: Text(
                      _describe(w, a).$2,
                      style: a == _TileMenuAction.delete
                          ? TextStyle(color: error)
                          : null,
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(a),
                  ),
                const SizedBox(height: AppTokens.space8),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) _run(w, picked);
  }

  void _onPointerDown(PointerDownEvent e) {
    if (_pressPointer != null) return; // 멀티터치는 무시.
    _pressPointer = e.pointer;
    _pressOrigin = e.position;
    _pressWidget = widget;
    _pressNavigator = Navigator.maybeOf(context);
    _pressMoved = false;
    _longPressArmed = false;
    _pressTimer?.cancel();
    _pressTimer = Timer(kLongPressTimeout, () {
      if (_pressPointer != null && !_pressMoved) {
        _longPressArmed = true;
        // 메뉴가 준비됐다는 촉각 신호 — 떼면 열린다.
        HapticFeedback.selectionClick();
      }
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _pressPointer || _pressOrigin == null) return;
    if ((e.position - _pressOrigin!).distance > kTouchSlop) _pressMoved = true;
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _pressPointer) return;
    final isLongPress = _longPressArmed && !_pressMoved;
    final pressed = _pressWidget;
    final navigator = _pressNavigator;
    _resetPress();
    if (!isLongPress) return;
    // 이 떼기에 이어지는 탭(편집 시트 열기)은 삼킨다. Listener 는 제스처 인식기보다
    // 먼저 이벤트를 받으므로 플래그가 탭 콜백보다 앞선다.
    _suppressNextTap = true;
    scheduleMicrotask(() => _suppressNextTap = false);
    if (pressed != null && navigator != null) {
      _openMenuSheet(navigator, pressed);
    }
  }

  void _resetPress([PointerCancelEvent? _]) {
    _pressTimer?.cancel();
    _pressTimer = null;
    _pressPointer = null;
    _pressOrigin = null;
    _pressWidget = null;
    _pressNavigator = null;
    _longPressArmed = false;
  }

  void _handleTap() {
    if (_suppressNextTap) return;
    widget.onTap?.call();
  }

  Widget _buildTile(BuildContext context, {required bool compact}) {
    final w = widget;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDone = todo.isDone;
    final isNote = _isNote;
    final isMobile = AppPlatform.isMobile;
    final color = todo.category.color;
    // 자식 보유 note 는 "섹션 헤딩" 으로 강조(진한 틴트 + 굵은 제목).
    final isNoteHeading = isNote && w.childCount > 0;
    // 모드별 날짜 라벨. isAllDay 면 시간 미출력 (00:00 금지).
    final dateLabel = isNote ? null : TodoDateLabel.format(todo);
    final metaStyle = theme.textTheme.bodySmall;
    final faint = scheme.onSurface.withValues(alpha: 0.55);

    // 드릴 가능 표시 "하위 N". 데스크탑(넓은 폭)은 trailing 에 chevron 과 함께,
    // 압축 폭은 메타 줄에 둔다(둘 중 하나만 렌더).
    final drillBadge = w.drillChildCount != null
        ? Row(
            key: ValueKey('todo-tile-drill-${todo.id}'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space8,
                  vertical: AppTokens.space2,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                ),
                child: Text(
                  '하위 ${w.drillChildCount}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ],
          )
        : null;

    // 메타 한 줄: 날짜 → 진행중 → 이월 → 하위 → 반복 → 설명 있음.
    final meta = <Widget>[
      if (dateLabel != null) Text(dateLabel, style: metaStyle),
      if (todo.isInProgress)
        _MetaChip(
          key: const ValueKey('todo-tile-inprogress-label'),
          label: '진행중',
          color: color,
          fontWeight: FontWeight.w700,
        ),
      if (w.isCarriedOver && !isDone)
        _MetaChip(
          key: const ValueKey('todo-tile-carryover-label'),
          label: '이월',
          color: scheme.tertiary,
        ),
      if (compact && drillBadge != null) drillBadge,
      if (w.hiddenSeriesCount > 0)
        _MetaChip(
          key: const ValueKey('todo-tile-series-badge'),
          label: '밀린 반복 외 ${w.hiddenSeriesCount}건',
          color: color,
        ),
      if (!isNote && todo.isInRecurringSeries)
        Icon(
          key: const ValueKey('todo-tile-recurring-icon'),
          Icons.repeat_rounded,
          size: 14,
          color: color.withValues(alpha: 0.85),
        ),
      // 설명이 있다는 표시 — 메모 타입 글리프(sticky_note)와 모양을 달리한다.
      if (!isNote && (todo.description ?? '').isNotEmpty)
        Icon(
          key: const ValueKey('todo-tile-description-hint'),
          Icons.notes_rounded,
          size: 14,
          color: faint,
        ),
    ];

    final title = Text(
      todo.title,
      // 최대 2줄 + 말줄임. 전체 제목은 타일 탭(편집 시트)에서.
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: isNoteHeading ? FontWeight.w700 : null,
        decoration: isDone ? TextDecoration.lineThrough : null,
        color: isDone ? scheme.onSurface.withValues(alpha: 0.45) : null,
      ),
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ((w.breadcrumb ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.space2),
            child: Text(
              w.breadcrumb!,
              key: const ValueKey('todo-tile-breadcrumb'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: faint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Row(
          children: [
            // note 는 "메모" 라벨 칩으로 명시 구분한다.
            if (isNote) ...[
              Container(
                key: const ValueKey('todo-tile-note-label'),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space8,
                  vertical: AppTokens.space2,
                ),
                decoration: BoxDecoration(
                  color: NoteVisual.labelBackground(todo.category),
                  borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                  border: Border.all(
                    color: NoteVisual.labelOutline(todo.category),
                  ),
                ),
                child: Text(
                  NoteVisual.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: NoteVisual.labelForeground(theme.brightness),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.space8),
            ],
            Flexible(child: title),
          ],
        ),
        // note 본문 2줄 프리뷰. 검색 발췌가 있으면 그쪽을 대신 보인다.
        if (w.snippet == null &&
            isNote &&
            (todo.description ?? '').trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.space4),
            child: Text(
              todo.description!.trim(),
              key: const ValueKey('todo-tile-note-preview'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (w.snippet != null)
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.space4),
            child: Text(
              w.snippet!,
              key: const ValueKey('todo-tile-search-snippet'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.space4),
            child: Wrap(
              key: const ValueKey('todo-tile-meta'),
              spacing: AppTokens.space8,
              runSpacing: AppTokens.space4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: meta,
            ),
          ),
      ],
    );

    // ── 왼쪽: chevron? + 컬러바 + 체크(또는 메모 글리프) ─────────────────
    final leading = <Widget>[
      if (w.isExpanded != null)
        InkWell(
          key: ValueKey('todo-tile-chevron-${todo.id}'),
          onTap: w.onToggleExpand,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.space2),
            child: Icon(
              w.isExpanded!
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_right_rounded,
              size: 20,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      // 3px 카테고리 컬러바 — 색은 신호일 뿐, 주인공은 체크와 제목.
      Container(
        key: const ValueKey('todo-tile-colorbar'),
        width: 3,
        height: 32,
        decoration: BoxDecoration(
          color: isNote ? NoteVisual.accent(todo.category) : color,
          borderRadius: BorderRadius.circular(AppTokens.radiusFull),
        ),
      ),
      SizedBox(width: compact ? AppTokens.space4 : AppTokens.space8),
      if (isNote)
        SizedBox(
          width: compact ? 36 : 40,
          child: Icon(
            key: const ValueKey('todo-tile-note-leading'),
            Icons.sticky_note_2_outlined,
            size: 20,
            color: color,
          ),
        )
      else
        IconButton(
          key: const ValueKey('todo-tile-check'),
          onPressed: w.onToggle,
          icon: TodoStatusCheck(
            status: todo.status,
            color: color,
            size: compact ? 22 : 24,
          ),
          style: compact ? _kCompactIconButtonStyle : null,
          visualDensity: compact ? null : VisualDensity.compact,
          tooltip: isDone ? '완료 취소' : '완료',
        ),
      SizedBox(width: compact ? AppTokens.space4 : AppTokens.space8),
    ];

    // ── 오른쪽(데스크탑): hover 때만 보이는 △ ↳ ⋮ ──────────────────────
    // 자리는 항상 잡아 둔다 — 마우스를 올릴 때 제목이 다시 줄바꿈되며 흔들리지
    // 않게. 투명할 때도 눌리지만, 마우스는 누르기 전에 반드시 이 줄 위를 지나므로
    // 실제로는 보이는 상태에서만 눌린다.
    final ellipsisActions = _menuActions(w, includeQuick: false);
    final hoverActions = isMobile
        ? const <Widget>[]
        : <Widget>[
            if (!isNote && w.onToggleInProgress != null)
              IconButton(
                key: const ValueKey('todo-tile-progress'),
                onPressed: w.onToggleInProgress,
                icon: InProgressTriangle(
                  active: todo.isInProgress,
                  color: color,
                  size: 16,
                ),
                style: compact ? _kCompactIconButtonStyle : null,
                visualDensity: compact ? null : VisualDensity.compact,
                tooltip: todo.isInProgress ? '진행중 해제' : '진행중',
              ),
            if (w.onAddChild != null)
              IconButton(
                key: ValueKey('todo-tile-add-child-${todo.id}'),
                onPressed: w.onAddChild,
                icon: const Icon(Icons.subdirectory_arrow_right_rounded),
                iconSize: 18,
                color: faint,
                style: compact ? _kCompactIconButtonStyle : null,
                visualDensity: compact ? null : VisualDensity.compact,
                tooltip: '하위 추가',
              ),
            if (ellipsisActions.isNotEmpty)
              PopupMenuButton<_TileMenuAction>(
                key: ValueKey('todo-tile-menu-${todo.id}'),
                icon: Icon(Icons.more_vert, size: 18, color: faint),
                tooltip: '더보기',
                padding: EdgeInsets.zero,
                style: compact ? _kCompactIconButtonStyle : null,
                onOpened: () => setState(() => _hovered = true),
                onCanceled: () => setState(() => _hovered = false),
                onSelected: (a) {
                  setState(() => _hovered = false);
                  _run(w, a);
                },
                itemBuilder: (context) =>
                    _popupItems(context, w, ellipsisActions),
              ),
          ];

    Widget row = Row(
      children: [
        ...leading,
        Expanded(
          // 완료 행은 전체 탈색 — 체크(●)만 또렷하게 남긴다.
          child: Opacity(opacity: isDone ? 0.6 : 1, child: content),
        ),
        if (!compact && drillBadge != null)
          Padding(
            padding: const EdgeInsets.only(left: AppTokens.space4),
            child: drillBadge,
          ),
        if (hoverActions.isNotEmpty)
          AnimatedOpacity(
            key: const ValueKey('todo-tile-hover-actions'),
            opacity: _hovered ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: Row(mainAxisSize: MainAxisSize.min, children: hoverActions),
          ),
      ],
    );

    Widget tile = Card(
      // note 는 카테고리색 틴트 배경(헤딩=진한 틴트 / leaf=연한 틴트).
      color: isNoteHeading
          ? NoteVisual.headingTint(todo.category, theme.brightness)
          : isNote
          ? NoteVisual.tint(todo.category, theme.brightness)
          : null,
      child: InkWell(
        onTap: w.onTap == null ? null : _handleTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? AppTokens.space8 : AppTokens.space12,
            AppTokens.space8,
            AppTokens.space8,
            AppTokens.space8,
          ),
          child: row,
        ),
      ),
    );

    if (isMobile) {
      tile = Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _resetPress,
        child: tile,
      );
    } else {
      tile = MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onSecondaryTapUp: (d) => _openContextMenu(d.globalPosition),
          child: tile,
        ),
      );
    }
    return tile;
  }
}

/// 메타 줄의 작은 pill 라벨 — "진행중" / "이월" / "밀린 반복 외 N건".
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    super.key,
    required this.label,
    required this.color,
    this.fontWeight = FontWeight.w600,
  });

  final String label;
  final Color color;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space8,
        vertical: AppTokens.space2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTokens.radiusFull),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: color, fontWeight: fontWeight),
      ),
    );
  }
}

/// [TodoTile] 메뉴 액션. 우클릭·길게 누르기 메뉴는 전부, ⋮ 는 edit 이하만.
enum _TileMenuAction {
  inProgress,
  addChild,
  edit,
  move,
  copy,
  stopRecurrence,
  delete,
}
