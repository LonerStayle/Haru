import 'package:flutter/material.dart';

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/todo.dart';
import 'in_progress_triangle.dart';

/// 모바일 압축 모드의 trailing 버튼 터치 타겟.
///
/// 기본 [IconButton] 은 48dp 를 먹는데, 세모(진행중) + 체크(완료) + ⋮(더보기)
/// 3개가 붙으면 좁은 폰 폭에서 제목이 쓸 폭이 거의 남지 않아 세로로 무한 wrap
/// 되었다(대표님 리포트). 36dp 는 손가락으로 누르기엔 여전히 충분하면서
/// 3버튼 합계를 144dp → 108dp 로 줄인다.
/// (IconButton 의 `constraints` 만으로는 부족하다 — Material 3 는 그와 별개로
/// 48dp tap target 패딩을 덧대므로 `tapTargetSize.shrinkWrap` 까지 필요하다.)
const ButtonStyle _kCompactIconButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(36, 36)),
  fixedSize: WidgetStatePropertyAll(Size(36, 36)),
  maximumSize: WidgetStatePropertyAll(Size(36, 36)),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 한 줄짜리 Todo 카드 — 카테고리 컬러바 + 제목 + 시간 + 체크 아이콘.
///
/// 체크/편집/삭제 동작은 phase 5 의 "체크 흐름" task 에서 [onToggle] / [onTap] 등으로
/// 연결한다. 지금은 표시만.
class TodoTile extends StatelessWidget {
  const TodoTile({
    super.key,
    required this.todo,
    this.onToggle,
    this.onToggleInProgress,
    this.onTap,
    this.onAddChild,
    this.onCopy,
    this.onEditItem,
    this.onDelete,
    this.isExpanded,
    this.onToggleExpand,
    this.childCount = 0,
    this.drillChildCount,
    this.hiddenSeriesCount = 0,
    this.onStopRecurrence,
  });

  final Todo todo;
  final VoidCallback? onToggle;

  /// 진행중(세모) 토글. null 이면 세모 버튼 미표시 (진행중 미지원 화면 / note).
  final VoidCallback? onToggleInProgress;

  final VoidCallback? onTap;

  /// 더보기(⋮) 메뉴 — 이 항목을 복사 (제목·내용·카테고리·날짜/종류를 채운 새 항목 시트).
  /// null 이면 메뉴에서 '복사' 항목 미표시.
  final VoidCallback? onCopy;

  /// 더보기(⋮) 메뉴 — 이 항목 자체를 편집. (폴더든 leaf 든 그 항목 편집 시트.)
  /// null 이면 메뉴에서 '편집' 항목 미표시.
  final VoidCallback? onEditItem;

  /// 더보기(⋮) 메뉴 — 이 항목 삭제. null 이면 메뉴에서 '삭제' 항목 미표시.
  final VoidCallback? onDelete;

  /// Task C — "＋ 하위 추가" 콜백. null 이면 버튼 미표시 (note 타입 등). task 만 자식 가능.
  final VoidCallback? onAddChild;

  /// Task C — 접힘/펼침 상태. null 이면 자식이 없어 chevron 미표시. (인라인 트리 전용)
  final bool? isExpanded;

  /// Task C — chevron tap 콜백 (펼침/접힘 토글). isExpanded != null 일 때만 의미.
  final VoidCallback? onToggleExpand;

  /// Task C — 직속 자식 수 (>0 이면 폴더로 간주, 체크 진척률 배지 표시 가능). 현재는
  /// chevron 표시 판단에 isExpanded 와 함께 사용.
  final int childCount;

  /// 기능 M — 드릴다운 모드. non-null 이면 "자식 N + chevron_right" 배지를 trailing
  /// 앞에 표시(드릴 가능 표시). 타일 탭이 상세 화면 push 임을 시각적으로 알린다.
  /// 인라인 펼침(isExpanded) 과는 상호 배타 — 드릴 리스트에서만 사용.
  final int? drillChildCount;

  /// date-repeat (FR-4) — 같은 반복 시리즈의 숨겨진 미체크 건수. >0 이면 이 타일이
  /// leader 이며 "외 N건" 묶음 배지를 표시한다. 0 이면 배지 없음.
  final int hiddenSeriesCount;

  /// date-repeat (FR-6) — 더보기(⋮) 메뉴의 '반복 중지'. 반복 시리즈 항목일 때만
  /// 메뉴에 노출된다(null 이거나 비반복이면 미표시). 누르면 시리즈 마스터를 삭제한다.
  final VoidCallback? onStopRecurrence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDone = todo.isDone;
    final isInProgress = todo.isInProgress;
    final isNote = todo.type == TodoType.note;
    // §14 — 자식 보유 note 는 "섹션 헤딩" 으로 강조(진한 틴트 + 굵은 제목).
    // 자식 0 인 note 는 §13 의 leaf 메모(연한 틴트 카드).
    final isNoteHeading = isNote && childCount > 0;
    // fast-tasks — 모드별 날짜 라벨. isAllDay 면 시간 미출력 (00:00 금지).
    final dateLabel = isNote ? null : TodoDateLabel.format(todo);
    // 모바일 압축 레이아웃 — 폰 폭에서만 적용. 데스크탑은 폭이 넉넉하므로 현행 유지.
    // (제목 2줄 clamp / trailing 36dp / 메타 칩 한 줄 Wrap)
    final compact = AppPlatform.isMobile;

    // 제목 아래 메타 조각들. 데스크탑은 지금처럼 세로로 쌓고, 모바일은 한 줄
    // Wrap 으로 묶어 타일 높이를 줄인다. 정의는 여기 한 곳에서만 한다.
    final inProgressChip = isInProgress
        ? _MetaChip(
            key: const ValueKey('todo-tile-inprogress-label'),
            label: '진행중',
            color: todo.category.color,
            fontWeight: FontWeight.w700,
          )
        : null;
    final seriesChip = hiddenSeriesCount > 0
        ? _MetaChip(
            key: const ValueKey('todo-tile-series-badge'),
            label: '밀린 반복 외 $hiddenSeriesCount건',
            color: todo.category.color,
          )
        : null;
    // 기능 M — 드릴 가능 표시. "하위 N" + chevron_right. 탭하면 상세 화면 push.
    // 데스크탑은 trailing 에, 모바일은 메타 줄에 놓는다(둘 중 하나만 렌더).
    final drillBadge = drillChildCount != null
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
                  '하위 $drillChildCount',
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
    final dateText = dateLabel != null
        ? Text(dateLabel, style: theme.textTheme.bodySmall)
        : null;
    // 모바일 한 줄 메타: 날짜 → 진행중 → 하위 → 반복묶음 순.
    final compactMeta = <Widget>[
      ?dateText,
      ?inProgressChip,
      ?drillBadge,
      ?seriesChip,
    ];

    return Card(
      // §13/§14 — note 는 카테고리색 틴트 배경(헤딩=진한 틴트 / leaf=연한 틴트),
      // task 는 null=기본 surface.
      color: isNoteHeading
          ? NoteVisual.headingTint(todo.category, theme.brightness)
          : isNote
          ? NoteVisual.tint(todo.category, theme.brightness)
          : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusM),
        child: Padding(
          padding: EdgeInsets.symmetric(
            // 모바일은 좌우 여백도 한 단계 좁혀 제목 폭을 8dp 더 확보.
            horizontal: compact ? AppTokens.space12 : AppTokens.space16,
            vertical: AppTokens.space12,
          ),
          child: Row(
            children: [
              // Task C — 자식이 있으면 펼침/접힘 chevron. 없으면 컬러바만.
              if (isExpanded != null)
                InkWell(
                  key: ValueKey('todo-tile-chevron-${todo.id}'),
                  onTap: onToggleExpand,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(AppTokens.space2),
                    child: Icon(
                      isExpanded!
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_right_rounded,
                      size: 20,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              // §13 — task = 8px 카테고리 컬러바. note = 3px accent 보더(틴트 배경
              // 위라 얇은 accent 로 충분). 8px 컬러바와의 시각 충돌을 피한다.
              Container(
                key: const ValueKey('todo-tile-colorbar'),
                width: isNote ? NoteVisual.accentWidth : 8,
                height: 36,
                decoration: BoxDecoration(
                  color: isNote
                      ? NoteVisual.accent(todo.category)
                      : todo.category.color,
                  borderRadius: BorderRadius.circular(AppTokens.radiusS),
                ),
              ),
              // §13 — note 는 시선이 먼저 닿는 좌측에 카테고리색 메모 글리프.
              // 체크 affordance 는 note 어디에도 없음(trailing 도 제거).
              if (isNote) ...[
                const SizedBox(width: AppTokens.space8),
                Icon(
                  key: const ValueKey('todo-tile-note-leading'),
                  Icons.sticky_note_2_outlined,
                  size: 20,
                  color: todo.category.color,
                ),
              ],
              const SizedBox(width: AppTokens.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // §13 — note 는 "메모" 라벨 칩으로 명시 구분한다. 한글은 italic
                        // 글리프가 거의 없어 기존 italic 대신 라벨+틴트로 구분 신호를 옮긴다.
                        if (isNote) ...[
                          Container(
                            key: const ValueKey('todo-tile-note-label'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppTokens.space8,
                              vertical: AppTokens.space2,
                            ),
                            decoration: BoxDecoration(
                              color: NoteVisual.labelBackground(todo.category),
                              borderRadius: BorderRadius.circular(
                                AppTokens.radiusFull,
                              ),
                              border: Border.all(
                                color: NoteVisual.labelOutline(todo.category),
                              ),
                            ),
                            child: Text(
                              NoteVisual.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: NoteVisual.labelForeground(
                                  theme.brightness,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppTokens.space8),
                        ],
                        Flexible(
                          child: Text(
                            todo.title,
                            // 모바일은 최대 2줄 + 말줄임(대표님 확정). 좁은 폭에서
                            // 제목이 한두 글자씩 끝없이 wrap 되던 문제를 끊는다.
                            // 전체 제목은 타일 탭(편집 시트)에서 확인.
                            maxLines: compact ? 2 : null,
                            overflow: compact ? TextOverflow.ellipsis : null,
                            style: theme.textTheme.titleMedium?.copyWith(
                              // §14 — 헤딩 note 는 굵게(섹션 제목 강조).
                              fontWeight: isNoteHeading
                                  ? FontWeight.w700
                                  : null,
                              decoration: isDone
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: isDone
                                  ? scheme.onSurface.withValues(alpha: 0.45)
                                  : null,
                            ),
                          ),
                        ),
                        // v1.2 — task 는 description 있으면 작은 힌트 아이콘. note 는
                        // §13 에서 본문 프리뷰를 직접 노출하므로 힌트 아이콘 생략.
                        if (!isNote && (todo.description ?? '').isNotEmpty) ...[
                          const SizedBox(width: AppTokens.space8),
                          Icon(
                            key: const ValueKey('todo-tile-description-hint'),
                            Icons.sticky_note_2_outlined,
                            size: 14,
                            color: scheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ],
                        // date-repeat (FR-7) — 반복 시리즈 항목임을 알리는 아이콘.
                        if (!isNote && todo.isInRecurringSeries) ...[
                          const SizedBox(width: AppTokens.space8),
                          Icon(
                            key: const ValueKey('todo-tile-recurring-icon'),
                            Icons.repeat_rounded,
                            size: 14,
                            color: todo.category.color.withValues(alpha: 0.85),
                          ),
                        ],
                      ],
                    ),
                    // 진행중 3-상태 — 진행중이면 제목 아래 작은 "진행중" 라벨(문구 신호).
                    // 완료 취소선/흐림(isDone)과 상호배타 — 진행중은 취소선 없음.
                    // (모바일은 아래 compact 메타 줄에서 한 줄로 묶어 표시한다.)
                    if (!compact && inProgressChip != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.space4),
                        child: inProgressChip,
                      ),
                    // §13 — note 본문(description) 2줄 프리뷰. "정보=메모" 를 즉시 전달.
                    // task 는 미노출(위 힌트 아이콘 유지), 빈 description note 는 생략.
                    if (isNote && (todo.description ?? '').trim().isNotEmpty)
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
                    if (!compact && dateText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.space2),
                        child: dateText,
                      ),
                    // date-repeat (FR-4) — 같은 반복 미체크 누적 묶음 배지.
                    if (!compact && seriesChip != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.space4),
                        child: seriesChip,
                      ),
                    // 모바일 — 날짜/진행중/하위/반복 묶음을 한 줄 Wrap 으로 합쳐
                    // 타일이 세로로 길어지는 것을 막는다.
                    if (compact && compactMeta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AppTokens.space4),
                        child: Wrap(
                          spacing: AppTokens.space8,
                          runSpacing: AppTokens.space4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: compactMeta,
                        ),
                      ),
                  ],
                ),
              ),
              // 기능 M — 드릴 가능 표시. "자식 N" + chevron_right. 탭하면 상세 화면 push.
              // (모바일은 제목 아래 메타 줄로 내려 trailing 폭을 비운다.)
              if (!compact && drillBadge != null)
                Padding(
                  padding: const EdgeInsets.only(left: AppTokens.space4),
                  child: drillBadge,
                ),
              // §14 — note 도 "섹션 헤딩" 으로 자식 보유 가능 → 타입 무관 ＋하위 추가.
              if (onAddChild != null)
                IconButton(
                  key: ValueKey('todo-tile-add-child-${todo.id}'),
                  onPressed: onAddChild,
                  icon: const Icon(Icons.subdirectory_arrow_right_rounded),
                  iconSize: 18,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                  style: compact ? _kCompactIconButtonStyle : null,
                  visualDensity: compact ? null : VisualDensity.compact,
                  tooltip: '하위 추가',
                ),
              // 진행중 3-상태 — 완료 체크(원) 왼쪽에 진행중(세모) 버튼. onToggleInProgress
              // 가 배선된 화면(오늘/카테고리/상세/타임라인)에서만 노출. note 는 제외.
              if (!isNote && onToggleInProgress != null)
                IconButton(
                  key: const ValueKey('todo-tile-progress'),
                  onPressed: onToggleInProgress,
                  icon: InProgressTriangle(
                    active: isInProgress,
                    color: todo.category.color,
                  ),
                  style: compact ? _kCompactIconButtonStyle : null,
                  visualDensity: compact ? null : VisualDensity.compact,
                  tooltip: isInProgress ? '진행중 해제' : '진행중',
                ),
              // §13 — note 는 trailing 을 비운다(체크 affordance 부재 명확화 — 메모는
              // 좌측 글리프로만 식별). task 만 trailing 체크 버튼.
              if (!isNote)
                IconButton(
                  key: const ValueKey('todo-tile-check'),
                  onPressed: onToggle,
                  icon: Icon(
                    isDone
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    // §13 — 미완료도 카테고리색 ring(0.55) 으로 "체크 가능" 신호 + 대비
                    // 강화(기존 회색 0.35 는 너무 옅었다). 완료는 카테고리색 원색.
                    color: isDone
                        ? todo.category.color
                        : todo.category.color.withValues(alpha: 0.55),
                  ),
                  iconSize: compact ? 22 : null,
                  style: compact ? _kCompactIconButtonStyle : null,
                  tooltip: isDone ? '완료 취소' : '완료',
                ),
              // 더보기(⋮) 메뉴 — 복사 / 편집 / 반복중지 / 삭제. 하나라도 있으면 노출.
              if (onCopy != null ||
                  onEditItem != null ||
                  onDelete != null ||
                  (onStopRecurrence != null && todo.isInRecurringSeries))
                PopupMenuButton<_TileMenuAction>(
                  key: ValueKey('todo-tile-menu-${todo.id}'),
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                  tooltip: '더보기',
                  padding: EdgeInsets.zero,
                  // PopupMenuButton 은 내부 IconButton 에 constraints 를 넘길 수
                  // 없어 style 로 36dp 를 지정한다(기본 48dp tap target 해제).
                  style: compact ? _kCompactIconButtonStyle : null,
                  onSelected: (action) {
                    switch (action) {
                      case _TileMenuAction.copy:
                        onCopy?.call();
                      case _TileMenuAction.edit:
                        onEditItem?.call();
                      case _TileMenuAction.stopRecurrence:
                        onStopRecurrence?.call();
                      case _TileMenuAction.delete:
                        onDelete?.call();
                    }
                  },
                  itemBuilder: (context) => [
                    if (onCopy != null)
                      const PopupMenuItem(
                        value: _TileMenuAction.copy,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.copy_outlined, size: 18),
                          title: Text('복사'),
                        ),
                      ),
                    if (onEditItem != null)
                      const PopupMenuItem(
                        value: _TileMenuAction.edit,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.edit_outlined, size: 18),
                          title: Text('편집'),
                        ),
                      ),
                    // date-repeat — 반복 시리즈 항목만 '반복 중지' 노출.
                    if (onStopRecurrence != null && todo.isInRecurringSeries)
                      const PopupMenuItem(
                        value: _TileMenuAction.stopRecurrence,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.repeat_rounded, size: 18),
                          title: Text('반복 중지'),
                        ),
                      ),
                    if (onDelete != null)
                      PopupMenuItem(
                        value: _TileMenuAction.delete,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: scheme.error,
                          ),
                          title: Text(
                            '삭제',
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 제목 아래 메타 줄의 작은 pill 라벨 — "진행중" / "밀린 반복 외 N건".
///
/// 데스크탑은 세로로 쌓이고, 모바일은 날짜·하위 배지와 한 줄 Wrap 으로 묶인다.
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

/// [TodoTile] 의 더보기(⋮) 메뉴 액션.
enum _TileMenuAction { copy, edit, stopRecurrence, delete }
