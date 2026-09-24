import 'package:flutter/material.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/todo.dart';
import 'todo_tile.dart';

/// [TodoTile] 을 [Dismissible] 로 감싸 폰 스와이프 동작을 붙인다 (UX Phase 1).
///
///  - 왼쪽으로 밀기 = 삭제 (errorContainer 배경 + 휴지통, 되돌리기는 호출자 스낵바)
///  - 오른쪽으로 밀기 = 완료 토글 (초록 배경 + 체크). 카드는 사라지지 않고 제자리로
///    돌아온다 — confirmDismiss 에서 토글만 하고 false 를 돌려준다.
class DismissibleTodoTile extends StatelessWidget {
  const DismissibleTodoTile({
    super.key,
    required this.todo,
    this.onToggle,
    this.onToggleInProgress,
    this.onDelete,
    this.onTap,
    this.confirmDismiss,
    this.onAddChild,
    this.onMove,
    this.onCopy,
    this.onEditItem,
    this.isExpanded,
    this.onToggleExpand,
    this.childCount = 0,
    this.drillChildCount,
    this.hiddenSeriesCount = 0,
    this.onStopRecurrence,
    this.breadcrumb,
    this.isCarriedOver = false,
  });

  /// 실수 swipe 방지를 위한 dismiss threshold. 0.4 (40%) 는 의도치 않은 살짝 swipe 으로도
  /// 즉시 삭제되던 case 가 있어 [_kSwipeThreshold] 로 상향. UndoSnackbar 가 회복 경로지만
  /// 1차 가드를 강화하는 게 더 안전.
  static const double _kSwipeThreshold = 0.6;

  /// 오른쪽 스와이프 완료 임계.
  static const double _kCompleteThreshold = 0.35;

  final Todo todo;
  final VoidCallback? onToggle;

  /// 진행중(세모) 토글. TodoTile 로 그대로 전달. null 이면 세모 버튼 미표시.
  final VoidCallback? onToggleInProgress;

  final VoidCallback? onDelete;

  /// v1.2 — tile tap → edit sheet 진입 등. null 이면 InkWell 비활성.
  final VoidCallback? onTap;

  /// 선택적 확인 콜백 — true 반환 시에만 dismiss. 일반 todo 는 swipe + UndoSnackbar 로
  /// 충분하지만 중요한 case (예: calendarEventId 있는 todo) 에서 호출자가 dialog 띄울 수 있게.
  final Future<bool> Function()? confirmDismiss;

  /// Task C — 트리 노드용. TodoTile 로 그대로 전달.
  final VoidCallback? onAddChild;

  /// 더보기(⋮) 메뉴 — 이동 / 복사 / 이 항목 편집. TodoTile 로 그대로 전달.
  final VoidCallback? onMove;
  final VoidCallback? onCopy;
  final VoidCallback? onEditItem;

  final bool? isExpanded;
  final VoidCallback? onToggleExpand;
  final int childCount;

  /// 기능 M — 드릴다운 모드 배지 (자식 N + chevron). TodoTile 로 전달.
  final int? drillChildCount;

  /// date-repeat (FR-4) — 같은 반복 시리즈 숨김 건수. TodoTile 로 전달.
  final int hiddenSeriesCount;

  /// date-repeat (FR-6) — ⋮ 메뉴 '반복 중지' 콜백. TodoTile 로 전달.
  final VoidCallback? onStopRecurrence;

  /// 상태별 보기 — 평탄 목록에서의 부모 경로. TodoTile 로 그대로 전달.
  final String? breadcrumb;

  /// 오늘 화면 — 이월 항목 표시. TodoTile 로 그대로 전달.
  final bool isCarriedOver;

  /// 오른쪽 스와이프(완료)는 체크가 있는 task 에만.
  bool get _canSwipeComplete => todo.type == TodoType.task && onToggle != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = _tile();

    // 데스크탑은 "밀어서 삭제" 를 끈다. Flutter 는 마우스(맥 트랙패드 클릭 포함)의 드래그
    // 판정 임계가 1px 이라, 클릭하는 동안 손이 살짝만 흔들려도 가로 드래그가 이겨 카드
    // 탭과 ○ 체크 클릭이 사라졌다 (대표님 제보 2026-09-25 "클릭 자체가 잘 안 된다").
    // 데스크탑 삭제는 ⋮ 메뉴 → 삭제(되돌리기 포함)로 한다. 모바일 스와이프는 그대로.
    if (AppPlatform.isDesktop) return tile;

    final canComplete = _canSwipeComplete;
    return Dismissible(
      key: ValueKey('todo-${todo.id}'),
      direction: canComplete
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      dismissThresholds: const {
        DismissDirection.endToStart: _kSwipeThreshold,
        // 완료는 되돌리기 쉬운 동작이라 삭제보다 가볍게.
        DismissDirection.startToEnd: _kCompleteThreshold,
      },
      confirmDismiss: !canComplete && confirmDismiss == null
          ? null
          : (direction) async {
              if (direction == DismissDirection.startToEnd) {
                onToggle?.call();
                return false; // 카드는 제자리로 — 상태만 바뀐다.
              }
              return confirmDismiss == null ? true : confirmDismiss!();
            },
      background: canComplete
          ? Container(
              key: const ValueKey('todo-swipe-complete-bg'),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.space20,
              ),
              decoration: BoxDecoration(
                color: AppPalette.success.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppTokens.radiusM),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    todo.isDone
                        ? Icons.undo_rounded
                        : Icons.check_circle_rounded,
                    color: AppPalette.success,
                  ),
                  const SizedBox(width: AppTokens.space8),
                  Text(
                    todo.isDone ? '완료 취소' : '완료',
                    style: TextStyle(
                      color: AppPalette.success,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.space20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
        ),
        child: Icon(
          Icons.delete_outline_rounded,
          color: scheme.onErrorContainer,
        ),
      ),
      onDismissed: (_) => onDelete?.call(),
      child: tile,
    );
  }

  TodoTile _tile() => TodoTile(
    todo: todo,
    onToggle: onToggle,
    onToggleInProgress: onToggleInProgress,
    onTap: onTap,
    onAddChild: onAddChild,
    onMove: onMove,
    onCopy: onCopy,
    onEditItem: onEditItem,
    onDelete: onDelete,
    isExpanded: isExpanded,
    onToggleExpand: onToggleExpand,
    childCount: childCount,
    drillChildCount: drillChildCount,
    hiddenSeriesCount: hiddenSeriesCount,
    onStopRecurrence: onStopRecurrence,
    breadcrumb: breadcrumb,
    isCarriedOver: isCarriedOver,
  );
}
