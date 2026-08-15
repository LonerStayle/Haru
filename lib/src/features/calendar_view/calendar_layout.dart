import 'calendar_entry.dart';

/// 월 그리드 한 화면의 행 수. **항상 6행 고정**.
///
/// 달마다 5행/6행이 오가면 스와이프로 달을 넘길 때 격자 높이가 튄다. 6행으로 고정하면
/// PageView 가 같은 높이를 유지해 이동이 매끄럽고, "모든 주 행 높이 균일" 요구도
/// 자동으로 충족된다. 남는 칸은 앞뒤 달의 넘침 날짜로 채워 흐리게 그린다.
const int calendarWeekRows = 6;

/// 한 주의 칸 수.
const int calendarDaysPerWeek = 7;

/// [month] 가 속한 달의 그리드 날짜 42개 (6행 × 7열). **일요일 시작.**
///
/// 앞뒤로 넘치는 날짜(이전 달 말 / 다음 달 초)를 포함한다 — 화면에서는 흐리게 그리되
/// 탭하면 그 달로 이동한다.
List<DateTime> monthGridDays(DateTime month) {
  final first = DateTime(month.year, month.month);
  // DateTime.weekday 는 월=1 … 일=7. 일요일 시작 그리드에서의 열 번호는 weekday % 7.
  final leading = first.weekday % calendarDaysPerWeek;
  final start = DateTime(first.year, first.month, first.day - leading);
  return List<DateTime>.generate(
    calendarWeekRows * calendarDaysPerWeek,
    // add(Duration(days:)) 는 DST 경계에서 시각이 밀린다. 날짜 필드 산술은 안전.
    (i) => DateTime(start.year, start.month, start.day + i),
  );
}

/// [gridDays] 를 7개씩 끊어 주 단위로 나눈다.
List<List<DateTime>> chunkIntoWeeks(List<DateTime> gridDays) => [
  for (var i = 0; i < gridDays.length; i += calendarDaysPerWeek)
    gridDays.sublist(i, i + calendarDaysPerWeek),
];

/// 두 date-only 날짜 사이의 일수. DST 와 무관하게 세려고 UTC 로 정규화해 뺀다.
int daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// 엔트리들을 **날짜별 버킷**으로 나눈다.
///
/// 기간 항목은 걸친 **모든 날짜 키**에 같은 엔트리가 들어간다 (칸마다 "이 날 이 일이
/// 있다"를 답해야 하므로). [rangeStart]~[rangeEnd] 바깥은 잘라내 헛도는 순회를 막는다.
///
/// 각 버킷은 [compareEntries] 로 정렬된 상태로 반환된다.
Map<DateTime, List<CalendarEntry>> bucketByDate({
  required Iterable<CalendarEntry> entries,
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  final start0 = dateOnly(rangeStart);
  final end0 = dateOnly(rangeEnd);
  final buckets = <DateTime, List<CalendarEntry>>{};

  for (final e in entries) {
    if (e.endDate.isBefore(start0) || e.startDate.isAfter(end0)) continue;
    var cursor = e.startDate.isBefore(start0) ? start0 : e.startDate;
    final last = e.endDate.isAfter(end0) ? end0 : e.endDate;
    while (!cursor.isAfter(last)) {
      buckets.putIfAbsent(cursor, () => <CalendarEntry>[]).add(e);
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
  }

  for (final list in buckets.values) {
    list.sort(compareEntries);
  }
  return buckets;
}

/// 같은 칸 안의 표시 순서.
///
/// 우선순위와 그 이유:
/// 1. **기간 막대 먼저** — 막대는 칸 상단에 레인으로 깔리므로 목록에서도 앞에 온다.
/// 2. **미완료 먼저** — 칸에는 상한(칩 3개 / 점 4개)이 있다. 완료가 자리를 먹고
///    미완료가 "외 N건" 뒤로 밀리면 달력을 보는 이유가 사라진다.
/// 3. **종일 먼저, 그 다음 시각 오름차순** — 하루의 실제 진행 순서.
/// 4. 나머지는 전 앱 공통 규칙: `sortOrder asc → createdAt desc → id asc`.
///    (정렬 키에 updatedAt 을 절대 넣지 않는다 — 체크·동기화로 자리가 튄다.)
int compareEntries(CalendarEntry a, CalendarEntry b) {
  if (a.spansMultipleDays != b.spansMultipleDays) {
    return a.spansMultipleDays ? -1 : 1;
  }
  if (a.isDone != b.isDone) return a.isDone ? 1 : -1;
  if (a.isAllDay != b.isAllDay) return a.isAllDay ? -1 : 1;

  final at = a.timeAnchorAt;
  final bt = b.timeAnchorAt;
  if (at != null && bt != null) {
    final byTime = at.compareTo(bt);
    if (byTime != 0) return byTime;
  }

  final bySort = a.sortOrder.compareTo(b.sortOrder);
  if (bySort != 0) return bySort;

  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;

  return a.entryKey.compareTo(b.entryKey);
}

/// 한 주 안에서 기간 막대가 차지하는 자리.
class BarSegment {
  const BarSegment({
    required this.entry,
    required this.startCol,
    required this.span,
    required this.lane,
    required this.continuesLeft,
    required this.continuesRight,
  });

  final CalendarEntry entry;

  /// 이 주 안에서 시작하는 열 (0=일요일 … 6=토요일).
  final int startCol;

  /// 걸치는 열 수 (1~7).
  final int span;

  /// 세로 레인 번호. 0 이 가장 위.
  final int lane;

  /// 이전 주에서 이어져 온 막대인가 (왼쪽 끝을 잘린 모양으로 그린다).
  final bool continuesLeft;

  /// 다음 주로 이어지는 막대인가 (오른쪽 끝을 잘린 모양으로 그린다).
  final bool continuesRight;

  int get endCol => startCol + span - 1;
}

/// [weekStart] 로 시작하는 한 주(7일)의 기간 막대를 겹치지 않게 레인에 배치한다.
///
/// 주 경계에서 막대가 잘리고 다음 주 첫 칸에서 이어지는 표현을
/// [BarSegment.continuesLeft] / [BarSegment.continuesRight] 로 전달한다.
///
/// 배치는 greedy — 시작 열이 이른 것부터, 같으면 긴 것부터 낮은 레인을 차지한다.
/// 이 순서를 고정해야 데이터가 그대로면 매 프레임 같은 레이아웃이 나온다.
List<BarSegment> layoutWeekBars(
  Iterable<CalendarEntry> entries,
  DateTime weekStart,
) {
  final start0 = dateOnly(weekStart);
  final end0 = DateTime(
    start0.year,
    start0.month,
    start0.day + calendarDaysPerWeek - 1,
  );

  final candidates = entries
      .where((e) => e.spansMultipleDays)
      .where((e) => !e.endDate.isBefore(start0) && !e.startDate.isAfter(end0))
      .toList();

  candidates.sort((a, b) {
    final aStart = daysBetween(start0, a.startDate).clamp(0, 6);
    final bStart = daysBetween(start0, b.startDate).clamp(0, 6);
    if (aStart != bStart) return aStart.compareTo(bStart);
    final aLen = daysBetween(a.startDate, a.endDate);
    final bLen = daysBetween(b.startDate, b.endDate);
    if (aLen != bLen) return bLen.compareTo(aLen);
    return a.entryKey.compareTo(b.entryKey);
  });

  // lane 별로 이미 채워진 열 집합. 겹치지 않는 가장 낮은 레인에 넣는다.
  final laneOccupancy = <Set<int>>[];
  final out = <BarSegment>[];

  for (final e in candidates) {
    final startCol = daysBetween(start0, e.startDate).clamp(0, 6);
    final endCol = daysBetween(start0, e.endDate).clamp(0, 6);
    final cols = {for (var c = startCol; c <= endCol; c++) c};

    var lane = 0;
    while (lane < laneOccupancy.length &&
        laneOccupancy[lane].intersection(cols).isNotEmpty) {
      lane++;
    }
    if (lane == laneOccupancy.length) laneOccupancy.add(<int>{});
    laneOccupancy[lane].addAll(cols);

    out.add(
      BarSegment(
        entry: e,
        startCol: startCol,
        span: endCol - startCol + 1,
        lane: lane,
        continuesLeft: e.startDate.isBefore(start0),
        continuesRight: e.endDate.isAfter(end0),
      ),
    );
  }
  return out;
}
