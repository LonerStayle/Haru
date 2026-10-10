import '../../domain/policies/description_checklist.dart';

/// AI 응답 검증 공통 규칙 — 순수 함수. 기능은 이것만 거쳐 화면에 올린다.
///
/// 원칙: 모양이 틀린 원소는 그 원소만 버린다. 날짜가 틀리면 날짜만 버리고 항목은 살린다.
abstract final class AiJson {
  /// 객체 배열만 골라낸다. 배열이 아니면 빈 목록.
  static List<Map<String, dynamic>> objects(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is Map) e.cast<String, dynamic>(),
  ];

  static int? integer(Object? v) => switch (v) {
    int() => v,
    double() when v == v.roundToDouble() => v.toInt(),
    String() => int.tryParse(v.trim()),
    _ => null,
  };

  /// 문자열이면 trim, 비면 null.
  static String? text(Object? v, {int? max}) {
    if (v is! String) return null;
    final t = v.trim();
    if (t.isEmpty) return null;
    return max != null && t.length > max ? t.substring(0, max).trim() : t;
  }

  /// 할 일 제목 — 목록 기호·강조 기호를 벗기고 한 줄로, [max] 자에서 자른다.
  static String? title(Object? v, {int max = 120}) {
    if (v is! String) return null;
    final oneLine = v.replaceAll(RegExp(r'\s*\n\s*'), ' ');
    return text(DescriptionChecklist.stripListLine(oneLine), max: max);
  }

  /// 공백·줄바꿈을 하나로 접은 뒤 [phrase] 가 [source] 에 들어 있는지 — "원문에 적힌
  /// 것만" 의 기계적 확인.
  static bool appearsIn(String? phrase, String source) {
    if (phrase == null) return false;
    final p = _squash(phrase);
    return p.isNotEmpty && _squash(source).contains(p);
  }

  static String _squash(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  static final _date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static final _time = RegExp(r'^(\d{1,2}):(\d{2})$');

  /// AI 가 준 로컬 날짜(`YYYY-MM-DD`)·시각(`HH:mm`)을 로컬 [DateTime] 으로.
  ///
  /// `DateTime.parse` 를 쓰지 않는다 — 2/30 → 3/2 같은 정규화와 UTC 해석을 막는다.
  /// 범위는 [today] 기준 -7일 ~ +400일. 틀리면 null.
  static AiDate? date(Object? date, Object? time, {required DateTime today}) {
    if (date is! String) return null;
    final m = _date.firstMatch(date.trim());
    if (m == null) return null;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    final day = DateTime(y, mo, d);
    if (day.year != y || day.month != mo || day.day != d) return null;
    final base = DateTime(today.year, today.month, today.day);
    if (day.isBefore(base.subtract(const Duration(days: 7))) ||
        day.isAfter(base.add(const Duration(days: 400)))) {
      return null;
    }
    if (time is String) {
      final t = _time.firstMatch(time.trim());
      if (t != null) {
        final h = int.parse(t[1]!), mi = int.parse(t[2]!);
        if (h <= 23 && mi <= 59) {
          return AiDate(DateTime(y, mo, d, h, mi), allDay: false);
        }
      }
    }
    return AiDate(day, allDay: true);
  }

  /// AI 로 보내는 로컬 날짜 표기 — 종일이면 `YYYY-MM-DD`, 시각이 있으면 `YYYY-MM-DD HH:mm`.
  /// UTC ISO 를 보내면 한국 종일 항목이 전날 15:00Z 로 보인다.
  static String localDate(DateTime t, {required bool allDay}) {
    final l = t.toLocal();
    final d =
        '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}';
    return allDay ? d : '$d ${_two(l.hour)}:${_two(l.minute)}';
  }

  /// 입력 머리의 오늘 — `2026-10-10(토)`.
  static String today(DateTime now) {
    const days = ['월', '화', '수', '목', '금', '토', '일'];
    return '${localDate(now, allDay: true)}(${days[now.toLocal().weekday - 1]})';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// AI 가 준 날짜 — 로컬 시각 + 종일 여부.
class AiDate {
  const AiDate(this.at, {required this.allDay});

  final DateTime at;
  final bool allDay;

  @override
  bool operator ==(Object other) =>
      other is AiDate && other.at == at && other.allDay == allDay;

  @override
  int get hashCode => Object.hash(at, allDay);

  @override
  String toString() => 'AiDate($at, allDay: $allDay)';
}
