import '../todo.dart';

/// "매달 손으로 다시 만드는 할 일" 감지 규칙 (2026-09-25).
///
/// 대표님은 관리비·대출금·전월세 제출 같은 월 단위 일을 달마다 새로 적는다
/// ("아파트 관리비 6월분 입금", "… 7월분 입금" …). 반복 기능은 있지만 쓰인 적이
/// 없어서, 이런 항목을 찾아 "매월 반복으로 만들기" 를 **제안**만 한다.
///
/// 판정: 제목에서 월 표시(`9월분`, `9월`, `2026년`, `9/23`)를 뺀 나머지가 같은
/// 최상위 할 일이, 같은 카테고리에서 **서로 다른 달 [minMonths]개 이상**에 걸쳐 있으면
/// 한 묶음. 달은 제목의 "N월" 을 우선, 없으면 만든 달로 센다.
/// 같은 묶음의 반복 마스터가 이미 있으면(반복으로 바꾼 뒤) 제안하지 않는다.
class MonthlyRepeatPolicy {
  const MonthlyRepeatPolicy._();

  static const minMonths = 3;

  static final _monthToken = RegExp(r'(\d{1,2})\s*월\s*(분)?');
  static final _yearToken = RegExp(r'\d{2,4}\s*년');
  static final _slashDate = RegExp(r'\d{1,2}/\d{1,2}');
  static final _spaces = RegExp(r'\s+');
  static final _letter = RegExp(r'[가-힣A-Za-z]');

  /// 제목에서 월·연·날짜 표시를 뺀, 반복 항목에 쓸 제목. 예: "아파트 관리비 입금".
  static String baseTitle(String title) => title
      .replaceAll(_yearToken, ' ')
      .replaceAll(_monthToken, ' ')
      .replaceAll(_slashDate, ' ')
      .replaceAll(_spaces, ' ')
      .trim();

  /// 묶음 키 — 띄어쓰기 차이("아파트관리비" / "아파트 관리비")도 같은 일로 본다.
  static String keyOf(String title) => baseTitle(title).replaceAll(' ', '');

  static int _monthOf(Todo t) {
    final m = _monthToken.firstMatch(t.title);
    final n = m == null ? null : int.tryParse(m.group(1)!);
    if (n != null && n >= 1 && n <= 12) return n;
    return t.createdAt.toLocal().month;
  }

  /// 할 일 id → 제안. 묶음에 속한 모든 항목이 같은 제안을 가리킨다.
  static Map<String, MonthlyRepeatSuggestion> detect(List<Todo> all) {
    final groups = <String, List<Todo>>{};
    final mastered = <String>{};
    for (final t in all) {
      if (t.type != TodoType.task || t.parentId != null) continue;
      final key = keyOf(t.title);
      if (key.length < 2 || !_letter.hasMatch(key)) continue;
      final gk = '${t.category.id}|$key';
      if (t.isSeriesMaster || t.seriesId != null) {
        mastered.add(gk);
        continue;
      }
      (groups[gk] ??= []).add(t);
    }
    final result = <String, MonthlyRepeatSuggestion>{};
    for (final entry in groups.entries) {
      if (mastered.contains(entry.key)) continue;
      final items = entry.value;
      // 달 표시가 없는 제목만 모인 묶음은 "매달" 이라는 근거가 약하다 — 같은 제목을
      // 여러 번 만든 것일 수 있다. 제목에 N월이 하나라도 있어야 한다.
      if (!items.any((t) => _monthToken.hasMatch(t.title))) continue;
      final months = {for (final t in items) _monthOf(t)};
      if (months.length < minMonths) continue;
      items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final latest = items.last;
      final anchor = (latest.dueAt ?? latest.createdAt).toLocal();
      final suggestion = MonthlyRepeatSuggestion(
        key: entry.key,
        title: baseTitle(latest.title),
        monthCount: months.length,
        dayOfMonth: anchor.day,
        latestDate: DateTime(anchor.year, anchor.month, anchor.day),
      );
      for (final t in items) {
        result[t.id] = suggestion;
      }
    }
    return result;
  }

  /// 반복의 첫 날짜 — 오늘 이후의 [MonthlyRepeatSuggestion.dayOfMonth] 이되, 마지막으로
  /// 손으로 만든 항목의 날짜가 이미 그 이후면 **그다음 달**부터(같은 날 두 건 방지).
  /// 예: "9월분" 을 10/21 로 잡아 뒀으면 반복은 11/21 부터.
  static DateTime firstDate(MonthlyRepeatSuggestion s, DateTime now) {
    final fromToday = nextDate(s.dayOfMonth, now);
    final latest = s.latestDate;
    if (fromToday.isAfter(latest)) return fromToday;
    return nextDate(
      s.dayOfMonth,
      DateTime(latest.year, latest.month, latest.day + 1),
    );
  }

  /// [dayOfMonth] 의 다음 날짜(오늘 포함). 그 달에 그 날이 없으면 말일.
  static DateTime nextDate(int dayOfMonth, DateTime now) {
    DateTime clamp(int y, int m) {
      final last = DateTime(y, m + 1, 0).day;
      return DateTime(y, m, dayOfMonth > last ? last : dayOfMonth);
    }

    final today = DateTime(now.year, now.month, now.day);
    final thisMonth = clamp(now.year, now.month);
    return thisMonth.isBefore(today)
        ? clamp(now.year, now.month + 1)
        : thisMonth;
  }
}

class MonthlyRepeatSuggestion {
  const MonthlyRepeatSuggestion({
    required this.key,
    required this.title,
    required this.monthCount,
    required this.dayOfMonth,
    required this.latestDate,
  });

  /// 묶음 키(카테고리|제목) — "그만 보기" 기억에 쓴다.
  final String key;
  final String title;
  final int monthCount;
  final int dayOfMonth;

  /// 가장 최근에 손으로 만든 항목의 날짜(날짜 없으면 만든 날, 로컬 자정).
  final DateTime latestDate;
}
