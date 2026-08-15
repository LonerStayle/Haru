/// 반복 규칙 값객체 (date-repeat).
///
/// 할 일의 "매일 / 매주(특정 요일) / 매월(특정 일) / 매년" 반복을 N간격과 함께 표현한다.
/// 외부 패키지(rrule) 없이 순수 Dart 로 발생일 계산 + RRULE 문자열 직렬화를 담당한다.
///
/// 설계 메모:
/// - 모든 날짜 계산은 **date-only(local 자정)** 기준. 시각/allDay 패턴은 마스터 Todo 의
///   dueAt/endAt/isAllDay/timeAnchor 가 따로 보유하므로 여기서는 "어느 날" 만 정한다.
/// - 발생 여부는 [_isOccurrence] 단일 predicate 로 판정하고, 열거/다음발생일은 그 위에
///   day-step 으로 구현 — 경계(월말/윤년/주간격)를 한 곳에서만 다루기 위함.
library;

/// 반복 주기.
enum RecurrenceFreq { daily, weekly, monthly, yearly }

/// 반복 규칙. 불변 값객체.
///
/// - [interval] — N간격 (1 이상). 예: weekly + interval 2 = "2주마다".
/// - [byWeekday] — weekly 전용. `DateTime.weekday` 표기(1=월 .. 7=일). 비어 있으면
///   anchor 의 요일을 사용. weekly 가 아니면 무시.
class RecurrenceRule {
  final RecurrenceFreq freq;
  final int interval;
  final Set<int> byWeekday;

  const RecurrenceRule({
    required this.freq,
    this.interval = 1,
    this.byWeekday = const {},
  }) : assert(interval >= 1, 'interval must be >= 1');

  // ── 발생일 계산 ────────────────────────────────────────────────────────────

  /// [after] 이후(strictly) 첫 발생일(date-only, local). [anchor] 는 반복 시작 기준일.
  ///
  /// 종료일은 여기서 고려하지 않는다 — 호출자(materializer)가 endAt 으로 컷.
  DateTime nextOccurrence(DateTime after, DateTime anchor) {
    final a = _dateOnly(anchor);
    final start = _dateOnly(after).add(const Duration(days: 1));
    var cursor = start.isBefore(a) ? a : start;
    // day-step 상한: 주기·간격에 비례한 넉넉한 가드 (무한루프 방지).
    final cap = _stepCapDays();
    for (var i = 0; i <= cap; i++) {
      if (_isOccurrence(cursor, a)) return cursor;
      cursor = cursor.add(const Duration(days: 1));
    }
    // 정상 규칙이라면 도달하지 않음. 방어적으로 cursor 반환.
    return cursor;
  }

  /// [anchor] 부터 [until](포함)까지의 모든 발생일(date-only, local), 오름차순.
  ///
  /// [maxCount] 로 폭주 방지 (기본 1000). materializer 가 과거 누락 채울 때 사용.
  List<DateTime> occurrencesUntil(
    DateTime anchor,
    DateTime until, {
    int maxCount = 1000,
  }) {
    final a = _dateOnly(anchor);
    final end = _dateOnly(until);
    final out = <DateTime>[];
    var cursor = a;
    while (!cursor.isAfter(end) && out.length < maxCount) {
      if (_isOccurrence(cursor, a)) out.add(cursor);
      cursor = cursor.add(const Duration(days: 1));
    }
    return out;
  }

  /// [date] 가 [anchor] 기준 이 규칙의 발생일인가? (둘 다 date-only 로 정규화해 비교)
  bool isOccurrenceOn(DateTime date, DateTime anchor) =>
      _isOccurrence(_dateOnly(date), _dateOnly(anchor));

  bool _isOccurrence(DateTime date, DateTime anchorDate) {
    if (date.isBefore(anchorDate)) return false;
    switch (freq) {
      case RecurrenceFreq.daily:
        final diff = date.difference(anchorDate).inDays;
        return diff % interval == 0;
      case RecurrenceFreq.weekly:
        final wds = byWeekday.isEmpty ? {anchorDate.weekday} : byWeekday;
        if (!wds.contains(date.weekday)) return false;
        final weeks =
            _mondayOf(date).difference(_mondayOf(anchorDate)).inDays ~/ 7;
        return weeks % interval == 0;
      case RecurrenceFreq.monthly:
        final months =
            (date.year - anchorDate.year) * 12 +
            (date.month - anchorDate.month);
        if (months < 0 || months % interval != 0) return false;
        final expectedDay = _min(
          anchorDate.day,
          _daysInMonth(date.year, date.month),
        );
        return date.day == expectedDay;
      case RecurrenceFreq.yearly:
        final years = date.year - anchorDate.year;
        if (years % interval != 0) return false;
        if (anchorDate.month == 2 && anchorDate.day == 29) {
          final expectedDay = _isLeap(date.year) ? 29 : 28;
          return date.month == 2 && date.day == expectedDay;
        }
        return date.month == anchorDate.month && date.day == anchorDate.day;
    }
  }

  int _stepCapDays() {
    switch (freq) {
      case RecurrenceFreq.daily:
        return interval + 1;
      case RecurrenceFreq.weekly:
        return interval * 7 + 7;
      case RecurrenceFreq.monthly:
        return interval * 31 + 31;
      case RecurrenceFreq.yearly:
        return interval * 366 + 366;
    }
  }

  // ── 직렬화 ────────────────────────────────────────────────────────────────

  /// DB 저장용 직렬화 (RRULE 본문, `RRULE:` prefix·UNTIL 제외).
  /// 예: `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE`
  String encode() {
    final parts = <String>['FREQ=${_freqToken(freq)}', 'INTERVAL=$interval'];
    if (freq == RecurrenceFreq.weekly && byWeekday.isNotEmpty) {
      final days = (byWeekday.toList()..sort()).map(_weekdayToken).join(',');
      parts.add('BYDAY=$days');
    }
    return parts.join(';');
  }

  /// [encode] 역변환. 미지 토큰은 무시하고 안전 복원. 파싱 실패 시 [FormatException].
  static RecurrenceRule decode(String s) {
    RecurrenceFreq? freq;
    var interval = 1;
    final byWeekday = <int>{};
    for (final pair in s.split(';')) {
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      final key = pair.substring(0, eq).trim().toUpperCase();
      final val = pair.substring(eq + 1).trim().toUpperCase();
      switch (key) {
        case 'FREQ':
          freq = _tokenToFreq(val);
        case 'INTERVAL':
          interval = int.tryParse(val) ?? 1;
        case 'BYDAY':
          for (final t in val.split(',')) {
            final wd = _tokenToWeekday(t.trim());
            if (wd != null) byWeekday.add(wd);
          }
      }
    }
    if (freq == null) throw FormatException('Invalid RecurrenceRule: $s');
    return RecurrenceRule(
      freq: freq,
      interval: interval < 1 ? 1 : interval,
      byWeekday: byWeekday,
    );
  }

  /// Google Calendar `recurrence` 항목용 RRULE 문자열.
  /// [until] 이 있으면 UTC 로 변환해 `UNTIL=yyyyMMddTHHmmssZ` 추가.
  String toRRule(DateTime? until) {
    final body = encode();
    if (until == null) return 'RRULE:$body';
    final u = until.toUtc();
    final stamp =
        '${_p4(u.year)}${_p2(u.month)}${_p2(u.day)}'
        'T${_p2(u.hour)}${_p2(u.minute)}${_p2(u.second)}Z';
    return 'RRULE:$body;UNTIL=$stamp';
  }

  /// [toRRule] 역변환 — Google Calendar 의 RRULE 문자열을 규칙 + 종료일로 되돌린다.
  ///
  /// **지원 범위를 일부러 좁혔다.** FREQ / INTERVAL / BYDAY(서수 없는 요일) / UNTIL
  /// 만 받고, 그 밖의 토큰(BYSETPOS · BYMONTHDAY · COUNT · 서수 BYDAY 등)이 하나라도
  /// 있으면 **null 을 반환**한다. 우리 모델(RecurrenceRule)이 표현하지 못하는 규칙을
  /// 억지로 근사하면, 되가져온 뒤 앱이 계산한 발생일이 구글 캘린더와 어긋난 채로
  /// 조용히 굴러간다 — 그것보다 "반복 없는 단일 할 일" 로 폴백하는 편이 정직하다.
  ///
  /// 앱에서 만든 반복은 항상 [toRRule] 이 낸 형태이므로 왕복은 언제나 성립한다.
  static ({RecurrenceRule rule, DateTime? until})? tryFromRRule(String raw) {
    var body = raw.trim();
    if (body.isEmpty) return null;
    if (body.toUpperCase().startsWith('RRULE:')) {
      body = body.substring('RRULE:'.length);
    }

    RecurrenceFreq? freq;
    var interval = 1;
    final byWeekday = <int>{};
    DateTime? until;

    for (final pair in body.split(';')) {
      if (pair.trim().isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) return null; // key=value 형태가 아니면 RRULE 이 아니다.
      final key = pair.substring(0, eq).trim().toUpperCase();
      final val = pair.substring(eq + 1).trim().toUpperCase();
      switch (key) {
        case 'FREQ':
          freq = _tokenToFreq(val);
          if (freq == null) return null; // HOURLY/MINUTELY 등 — 표현 불가.
        case 'INTERVAL':
          final n = int.tryParse(val);
          if (n == null || n < 1) return null;
          interval = n;
        case 'BYDAY':
          for (final t in val.split(',')) {
            final wd = _tokenToWeekday(t.trim());
            if (wd == null) return null; // '2MO' 같은 서수 접두사 포함.
            byWeekday.add(wd);
          }
        case 'UNTIL':
          until = _parseUntil(val); // 파싱 실패는 규칙 자체를 버리지 않는다.
        case 'WKST':
          break; // 주 시작 요일 — 우리 계산은 월요일 고정이라 무해하게 무시.
        default:
          return null; // 모르는 토큰이 있으면 근사하지 않고 포기한다.
      }
    }

    if (freq == null) return null;
    return (
      rule: RecurrenceRule(
        freq: freq,
        interval: interval,
        byWeekday: freq == RecurrenceFreq.weekly ? byWeekday : const {},
      ),
      until: until,
    );
  }

  // ── 사람용 한국어 요약 ──────────────────────────────────────────────────────

  /// 규칙을 한국어 한 줄로 요약. UI(편집 시트·상세·반복 관리)가 공유.
  /// 예: "매일", "2주마다 (월·수)", "매월 · 2026.12.31 까지".
  /// [until] 이 있으면 "· yyyy.MM.dd 까지" 를 덧붙인다.
  String describe({DateTime? until}) {
    final String base;
    if (interval == 1) {
      base = switch (freq) {
        RecurrenceFreq.daily => '매일',
        RecurrenceFreq.weekly => '매주',
        RecurrenceFreq.monthly => '매월',
        RecurrenceFreq.yearly => '매년',
      };
    } else {
      final unit = switch (freq) {
        RecurrenceFreq.daily => '일',
        RecurrenceFreq.weekly => '주',
        RecurrenceFreq.monthly => '개월',
        RecurrenceFreq.yearly => '년',
      };
      base = '$interval$unit마다';
    }

    final parts = <String>[base];
    if (freq == RecurrenceFreq.weekly && byWeekday.isNotEmpty) {
      const labels = ['월', '화', '수', '목', '금', '토', '일'];
      final days = (byWeekday.toList()..sort())
          .map((wd) => labels[wd - 1])
          .join('·');
      parts.add('($days)');
    }
    var summary = parts.join(' ');
    if (until != null) {
      final u = until.toLocal();
      summary = '$summary · ${_p4(u.year)}.${_p2(u.month)}.${_p2(u.day)} 까지';
    }
    return summary;
  }

  // ── 동등성 ────────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      other is RecurrenceRule &&
      other.freq == freq &&
      other.interval == interval &&
      _setEq(other.byWeekday, byWeekday);

  @override
  int get hashCode =>
      Object.hash(freq, interval, Object.hashAllUnordered(byWeekday));

  @override
  String toString() => 'RecurrenceRule(${encode()})';
}

// ── 내부 헬퍼 ──────────────────────────────────────────────────────────────

DateTime _dateOnly(DateTime d) {
  final l = d.toLocal();
  return DateTime(l.year, l.month, l.day);
}

DateTime _mondayOf(DateTime date) =>
    date.subtract(Duration(days: date.weekday - 1));

bool _isLeap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

int _daysInMonth(int year, int month) {
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month == 2 && _isLeap(year)) return 29;
  return days[month - 1];
}

int _min(int a, int b) => a < b ? a : b;

bool _setEq(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);

String _freqToken(RecurrenceFreq f) => switch (f) {
  RecurrenceFreq.daily => 'DAILY',
  RecurrenceFreq.weekly => 'WEEKLY',
  RecurrenceFreq.monthly => 'MONTHLY',
  RecurrenceFreq.yearly => 'YEARLY',
};

RecurrenceFreq? _tokenToFreq(String t) => switch (t) {
  'DAILY' => RecurrenceFreq.daily,
  'WEEKLY' => RecurrenceFreq.weekly,
  'MONTHLY' => RecurrenceFreq.monthly,
  'YEARLY' => RecurrenceFreq.yearly,
  _ => null,
};

const _weekdayTokens = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

String _weekdayToken(int wd) => _weekdayTokens[wd - 1];

int? _tokenToWeekday(String t) {
  final i = _weekdayTokens.indexOf(t);
  return i < 0 ? null : i + 1;
}

String _p2(int n) => n.toString().padLeft(2, '0');
String _p4(int n) => n.toString().padLeft(4, '0');

/// RRULE 의 `UNTIL` 값 파싱. `yyyyMMddTHHmmssZ` 와 `yyyyMMdd` 두 형태를 받는다.
/// 실패하면 null — 호출자가 종료일만 버리고 규칙은 살린다.
DateTime? _parseUntil(String v) {
  final s = v.trim();
  final m = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$',
  ).firstMatch(s);
  if (m == null) return null;
  int at(int i) => int.parse(m.group(i)!);
  return DateTime.utc(
    at(1),
    at(2),
    at(3),
    m.group(4) == null ? 0 : at(4),
    m.group(5) == null ? 0 : at(5),
    m.group(6) == null ? 0 : at(6),
  );
}
