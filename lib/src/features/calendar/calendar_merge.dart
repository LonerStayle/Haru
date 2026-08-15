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
  final patch = eventToTodoPatch(event);
  if (patch == null) return const MergeResult(MergeKind.unmappable);

  final signature = readHaruSignature(event);
  final localRev = local.updatedAt.toUtc().toIso8601String();
  final sameRev = signature.rev != null && signature.rev == localRev;

  // 서명이 우리 것과 같아도 **내용까지 같아야** echo 다.
  //
  // 사람이 구글 캘린더에서 제목이나 시간을 고쳐도 우리가 심어둔 서명은 그대로
  // 남는다. 서명만 보고 걸러내면 그 수정이 영영 앱에 반영되지 않는다 (왕복
  // 통합 테스트가 잡아낸 실제 결함). 반대로 내용까지 같으면 우리가 방금 올린
  // 그대로이므로 무시해야 루프가 끊긴다.
  if (sameRev && _sameContent(patch, local)) {
    return const MergeResult(MergeKind.echo);
  }

  final serverUpdated = event.updated;
  // 서명이 우리 것과 같은데 내용이 다르다 = 우리가 올린 뒤로 앱은 손대지 않았고
  // 캘린더에서만 바뀌었다는 뜻이다. 이때는 시각 비교 없이 캘린더를 따른다.
  if (!sameRev) {
    // 서버 시각이 없으면 어느 쪽이 최신인지 판단할 근거가 없다 — 앱을 신뢰한다.
    if (serverUpdated == null) return const MergeResult(MergeKind.localWins);
    if (!serverUpdated.toUtc().isAfter(local.updatedAt.toUtc())) {
      return const MergeResult(MergeKind.localWins);
    }
  }

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
      updatedAt: serverUpdated ?? local.updatedAt,
    ),
  );
}

/// 이벤트에서 뽑은 값이 로컬 할 일과 **내용상** 같은가.
///
/// 캘린더가 건드릴 수 있는 필드만 본다 — 카테고리·부모·정렬·완료는 앱에만 있는
/// 개념이라 비교 대상이 아니다.
bool _sameContent(EventDatePatch patch, Todo local) =>
    patch.title == local.title &&
    patch.dueAt == local.dueAt &&
    patch.endAt == local.endAt &&
    patch.isAllDay == local.isAllDay &&
    patch.timeAnchor == local.timeAnchor;
