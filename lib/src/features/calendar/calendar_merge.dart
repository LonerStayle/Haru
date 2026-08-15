import 'package:googleapis/calendar/v3.dart' as gcal;

import '../../domain/todo.dart';
import 'event_to_todo.dart';

/// 수신한 이벤트를 기존 할 일에 병합한 결과.
enum MergeKind {
  /// 우리가 쓴 변경이 되돌아왔다 — 아무것도 하지 않는다.
  echo,

  /// 캘린더 쪽이 더 최신이라 앱을 갱신했다.
  updated,

  /// 앱이 더 최신이라 무시했다 (다음 push 가 캘린더를 맞춘다).
  localWins,

  /// 이벤트에서 날짜를 뽑을 수 없어 병합 불가.
  unmappable,
}

class MergeResult {
  const MergeResult(this.kind, [this.merged]);

  final MergeKind kind;

  /// [MergeKind.updated] 일 때만 채워진다.
  final Todo? merged;
}

/// 수신한 [event] 를 [local] 할 일에 병합한다.
///
/// **echo 차단이 이 함수의 첫 번째 임무다.** 앱이 이벤트를 push 하면 구글은 그
/// 이벤트의 `updated` 를 방금 시각으로 스탬프한다. 그래서 시각만 비교하면 우리가 쓴
/// 변경이 항상 "캘린더가 더 최신" 으로 보여 앱을 갱신하고, 그 갱신이 다시 push 되어
/// **무한 루프**가 된다. push 할 때 심어둔 서명(`haruRev` = 그 시점의 `updatedAt`)이
/// 로컬 값과 같으면 우리가 쓴 것이므로 시각 비교 전에 걸러낸다.
///
/// 그 다음은 last-write-wins — 이벤트의 서버 수정 시각과 로컬 `updatedAt` 중 나중
/// 것이 이기고, 같으면 앱을 신뢰한다 (기존 Supabase 동기화의 LWW 와 같은 규칙).
///
/// 병합은 **제목과 날짜 계열만** 덮는다. 카테고리·부모·정렬·메모·완료 상태는 앱에만
/// 존재하는 개념이라 캘린더가 건드릴 수 없다.
MergeResult mergeEventIntoTodo({
  required gcal.Event event,
  required Todo local,
}) {
  final signature = readHaruSignature(event);
  final localRev = local.updatedAt.toUtc().toIso8601String();
  if (signature.rev != null && signature.rev == localRev) {
    return const MergeResult(MergeKind.echo);
  }

  final serverUpdated = event.updated;
  // 서버 시각이 없으면 어느 쪽이 최신인지 판단할 근거가 없다 — 앱을 신뢰한다.
  if (serverUpdated == null) return const MergeResult(MergeKind.localWins);
  if (!serverUpdated.toUtc().isAfter(local.updatedAt.toUtc())) {
    return const MergeResult(MergeKind.localWins);
  }

  final patch = eventToTodoPatch(event);
  if (patch == null) return const MergeResult(MergeKind.unmappable);

  return MergeResult(
    MergeKind.updated,
    local.copyWith(
      title: patch.title,
      dueAt: patch.dueAt,
      endAt: patch.endAt,
      isAllDay: patch.isAllDay,
      timeAnchor: patch.timeAnchor,
      recurrenceRule: patch.recurrence?.encode() ?? local.recurrenceRule,
      recurrenceEndAt: patch.recurrenceEndAt ?? local.recurrenceEndAt,
      // 서버 시각을 그대로 쓴다. 지금 시각으로 찍으면 로컬이 더 최신이 되어
      // 곧바로 캘린더로 되쏘게 되고, 그게 또 돌아와 루프가 된다.
      updatedAt: serverUpdated,
    ),
  );
}
