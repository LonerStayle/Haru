import '../../domain/todo.dart';
import 'calendar_entry.dart';
import 'calendar_layout.dart';

/// 캘린더에서 항목을 다른 날짜 칸에 떨어뜨렸을 때의 **날짜 치환 규칙**.
///
/// 핵심은 "날짜 부분만 바꾼다" 는 것이다. 사용자가 달력에서 항목을 옮기는 행위의
/// 의미는 *언제 할지* 를 바꾸는 것이지 *몇 시에 할지* 나 *며칠짜리인지* 를 바꾸는 게
/// 아니다. 그래서:
///
/// - 시각(hh:mm)과 [Todo.isAllDay] 는 그대로 보존한다.
/// - 기간 항목은 길이를 유지한 채 통째로 평행이동한다 ([Todo.endAt] 도 같은 delta).
/// - 날짜가 없던 항목([Todo.dueAt] == null, "날짜 없음" 서랍)에 떨어뜨리면 그 날짜가
///   부여되는데, 시각 정보가 아예 없으므로 **종일**로 만든다. (`00:00` 을 화면에
///   찍지 않는 전 앱 규칙은 `isAllDay == true` 로만 보장된다.)
///
/// [Todo.sortOrder] 는 건드리지 않는다 — 날짜 이동은 순서 조작이 아니다.
/// 순서 보존은 저장 경로(`TodoActionsController.setDueAt`)가 함께 책임진다.
Todo applyDateDrop(Todo todo, DateTime targetDate) {
  final target = dateOnly(targetDate);
  final due = todo.dueAt;

  if (due == null) {
    // 무날짜 → 날짜 부여. 시각을 모르므로 종일 단일 항목이 된다.
    return todo.copyWith(
      dueAt: target,
      endAt: null,
      isAllDay: true,
      timeAnchor: 'start',
    );
  }

  final dueLocal = due.toLocal();
  final delta = daysBetween(dateOnly(dueLocal), target);
  // 같은 날에 떨어뜨린 건 아무 변화가 아니다. 여기서 걸러야 저장 경로가
  // 헛돌지 않고 updatedAt 도 안 튄다.
  if (delta == 0) return todo;

  final newDue = _shiftDate(dueLocal, target.year, target.month, target.day);
  final end = todo.endAt?.toLocal();
  final newEnd = end == null
      ? null
      : _shiftDate(end, end.year, end.month, end.day + delta);

  // DB / Supabase 에서 온 값은 UTC 일 수 있다. 원본의 kind 를 그대로 유지해
  // 저장 후 다시 읽었을 때 하루가 밀리는 사고를 막는다.
  return todo.copyWith(
    dueAt: due.isUtc ? newDue.toUtc() : newDue,
    endAt: newEnd == null
        ? null
        : (todo.endAt!.isUtc ? newEnd.toUtc() : newEnd),
  );
}

/// [source] 의 시각 성분은 유지한 채 날짜만 [year]/[month]/[day] 로 바꾼다.
/// 날짜 필드 산술이라 DST 경계에서도 시각이 밀리지 않는다.
DateTime _shiftDate(DateTime source, int year, int month, int day) => DateTime(
  year,
  month,
  day,
  source.hour,
  source.minute,
  source.second,
  source.millisecond,
  source.microsecond,
);

/// 이 엔트리를 [targetDate] 로 옮기는 게 실제 변화인가.
///
/// 드롭 대상 칸을 하이라이트할지 판단하는 데 쓴다 — 원래 자리에 다시 놓는 동작에
/// 굳이 "여기 놓을 수 있음" 을 보여줄 필요가 없다.
bool isMeaningfulDrop(CalendarEntry entry, DateTime targetDate) =>
    !entry.startDate.isAtSameMomentAs(dateOnly(targetDate));
