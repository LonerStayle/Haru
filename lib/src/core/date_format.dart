import '../domain/todo.dart';

/// 가벼운 한국어 날짜 포맷터. intl 의 locale data 초기화 의존성 없이 동작.
///
/// 예: 2026-05-27 → "5월 27일 화요일"
class KoDate {
  const KoDate._();

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  static String pretty(DateTime d) =>
      '${d.month}월 ${d.day}일 ${_weekdays[d.weekday - 1]}요일';

  /// 시간만 — "14:30". 24h.
  static String time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// "M/D" — 짧은 날짜. 기간 표시용.
  static String shortDate(DateTime d) => '${d.month}/${d.day}';

  /// "M/D HH:mm" — 짧은 날짜 + 24h 시각.
  static String shortDateTime(DateTime d) => '${shortDate(d)} ${time(d)}';

  /// "2026년 8월" — 캘린더 월 헤더용. 연도를 붙이는 이유는 달을 넘겨 이동하다
  /// 해가 바뀌었는데 모르는 상황을 막기 위해서다.
  static String monthTitle(DateTime d) => '${d.year}년 ${d.month}월';

  /// "8월 15일 (토)" — 캘린더 선택일 헤더용. [pretty] 의 "…화요일" 보다 짧아
  /// 좁은 패널에서도 한 줄에 들어간다.
  static String dayWithWeekday(DateTime d) =>
      '${d.month}월 ${d.day}일 (${_weekdays[d.weekday - 1]})';

  /// 요일 한 글자 — 캘린더 그리드의 요일 헤더용.
  /// [weekday] 는 `DateTime.weekday` 규약 (1=월 … 7=일).
  static String weekdayShort(int weekday) => _weekdays[weekday - 1];
}

/// Todo 의 날짜·기간 모델을 화면용 짧은 라벨로 변환. 단일 출처.
///
/// fast-tasks 핵심: [Todo.isAllDay] 가 true 면 시간 컴포넌트를 절대 출력하지 않는다
/// ('00:00' / '오전 12:00' 금지). TodoTile / 기타 위치가 공유.
///
/// - none      → null (라벨 없음)
/// - allDay    → "5/27"
/// - startTime → "시작 5/27 14:30"
/// - endTime   → "마감 5/27 14:30"
/// - range     → "5/27 ~ 5/30" (+ !isAllDay 면 양끝 시각)
class TodoDateLabel {
  const TodoDateLabel._();

  static String? format(Todo todo) {
    final due = todo.dueAt;
    if (due == null) return null;
    switch (todo.dateMode) {
      case TodoDateMode.none:
        return null;
      case TodoDateMode.allDay:
        return KoDate.shortDate(due);
      case TodoDateMode.startTime:
        return '시작 ${KoDate.shortDateTime(due)}';
      case TodoDateMode.endTime:
        return '마감 ${KoDate.shortDateTime(due)}';
      case TodoDateMode.range:
        final end = todo.endAt;
        if (end == null) return KoDate.shortDate(due);
        if (todo.isAllDay) {
          return '${KoDate.shortDate(due)} ~ ${KoDate.shortDate(end)}';
        }
        return '${KoDate.shortDateTime(due)} ~ ${KoDate.shortDateTime(end)}';
    }
  }
}
