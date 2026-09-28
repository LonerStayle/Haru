import 'todo.dart';

/// 반복 마스터로부터 "발생일이 지난(=오늘까지)" 인스턴스 Todo 를 생성하는 순수 로직.
///
/// 설계(tech-design §3):
/// - lazy 생성 — anchor(master.dueAt)부터 **오늘까지만** 채운다. 미래분은 미리 안 만듦.
/// - idempotent — 이미 존재하는 `(seriesId, 발생일)` 은 건너뛴다(중복 가드).
/// - 종료일 컷 — `recurrenceEndAt` 이후 발생분은 만들지 않는다.
/// - 인스턴스는 마스터의 시각/기간/카테고리/타입 패턴을 복제하되 규칙은 보유하지 않는다.
class RecurrenceMaterializer {
  const RecurrenceMaterializer._();

  /// [masters] 중 활성 반복 마스터에 대해 [now] 기준 누락 인스턴스를 생성해 반환.
  ///
  /// [existingDatesBySeries] — seriesId → 이미 존재하는 인스턴스의 발생일(local date-only) 집합.
  /// [maxPerSeries] — 시리즈당 한 번에 만들 인스턴스 상한(오래 미실행 시 폭주 방지).
  ///
  /// 인스턴스 id 는 결정적([instanceId], `seriesId#yyyymmdd`) — 같은 (시리즈,발생일)은
  /// 항상 같은 id 라 재생성/다기기 동시생성에도 같은 row 를 덮어쓸 뿐 중복이 생기지 않는다.
  static List<Todo> materializeDue(
    List<Todo> masters,
    Map<String, Set<DateTime>> existingDatesBySeries,
    DateTime now, {
    int maxPerSeries = 400,
  }) {
    final today0 = _dateOnly(now);
    final out = <Todo>[];

    for (final m in masters) {
      if (!m.isRecurringMaster) continue;
      final rule = m.recurrence;
      final anchor = m.dueAt;
      final seriesId = m.seriesId;
      if (rule == null || anchor == null || seriesId == null) continue;

      // 종료일 컷: min(오늘, recurrenceEndAt 의 local date).
      var until = today0;
      final end = m.recurrenceEndAt;
      if (end != null) {
        final end0 = _dateOnly(end);
        if (end0.isBefore(until)) until = end0;
      }
      if (until.isBefore(_dateOnly(anchor))) continue;

      final existing = existingDatesBySeries[seriesId] ?? const <DateTime>{};
      final dates = rule.occurrencesUntil(
        anchor,
        until,
        maxCount: maxPerSeries,
      );
      for (final date in dates) {
        if (existing.contains(date)) continue;
        out.add(_instanceFor(m, date, instanceId(seriesId, date), now));
      }
    }
    return out;
  }

  /// v1.6 — 발생일 **하나만** 실체화. 캘린더에서 미래 회차를 건드릴 때 쓴다.
  ///
  /// [materializeDue] 는 `until = min(오늘, recurrenceEndAt)` 이라 **미래 회차를
  /// 절대 만들지 않는다**. 그래서 캘린더의 미래 반복은 DB 에 실체가 없는 고스트인데,
  /// 사용자가 체크·드래그·편집으로 건드리는 순간 조작할 row 가 필요해진다.
  /// 이 함수가 그 한 회차만 만들어준다.
  ///
  /// [materializeDue] 와 같은 [_instanceFor] / [instanceId] 를 재사용하므로 id 가
  /// 결정적이다 — 나중에 정규 실체화가 그 날짜에 도달해도 같은 row 를 덮어쓸 뿐
  /// 중복이 생기지 않는다. 새로운 저장 경로를 만들지 않는 것이 요점.
  ///
  /// null 반환: 반복 마스터가 아니거나 / [occLocalDate] 가 실제 발생일이 아니거나 /
  /// anchor 이전이거나 / 종료일([Todo.recurrenceEndAt])을 넘은 경우.
  static Todo? materializeOne(
    Todo master,
    DateTime occLocalDate,
    DateTime now,
  ) {
    if (!master.isRecurringMaster) return null;
    final rule = master.recurrence;
    final anchor = master.dueAt;
    final seriesId = master.seriesId;
    if (rule == null || anchor == null || seriesId == null) return null;

    final date = _dateOnly(occLocalDate);
    if (date.isBefore(_dateOnly(anchor))) return null;
    final end = master.recurrenceEndAt;
    if (end != null && date.isAfter(_dateOnly(end))) return null;
    if (!rule.isOccurrenceOn(date, anchor)) return null;

    return _instanceFor(master, date, instanceId(seriesId, date), now);
  }

  /// 결정적 인스턴스 id — `${seriesId}#yyyymmdd`(local date). 같은 (시리즈,발생일)은
  /// 항상 동일 → upsert 가 같은 row 를 덮어써 중복이 원천 차단된다.
  static String instanceId(String seriesId, DateTime occLocalDate) {
    final d = _dateOnly(occLocalDate);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$seriesId#$y$m$day';
  }

  /// 전체 Todo 목록에서 활성 반복 마스터만 추린다.
  static List<Todo> activeMasters(List<Todo> all) =>
      all.where((t) => t.isRecurringMaster).toList();

  /// 반복 항목([item], 인스턴스 또는 마스터)이 속한 시리즈의 마스터를 [all] 에서 찾는다.
  /// [item] 자체가 마스터면 그대로 반환. 시리즈 외 항목이거나 마스터가 없으면 null.
  /// "반복 중지"(마스터 삭제) 진입점이 사용 — 인스턴스에서 규칙 보유 마스터로 거슬러 올라간다.
  static Todo? findMaster(List<Todo> all, Todo item) {
    final sid = item.seriesId;
    if (sid == null) return null;
    if (item.isRecurringMaster) return item;
    for (final t in all) {
      if (t.id == sid && t.isRecurringMaster) return t;
    }
    return null;
  }

  /// 전체 Todo 목록에서 인스턴스의 발생일(local date-only)을 seriesId 별로 인덱싱.
  /// (마스터 자신은 제외 — 마스터의 dueAt 은 anchor 이지 인스턴스 발생분이 아니다.)
  static Map<String, Set<DateTime>> indexExistingInstanceDates(List<Todo> all) {
    final map = <String, Set<DateTime>>{};
    for (final t in all) {
      if (t.isSeriesMaster) continue;
      final sid = t.seriesId;
      final due = t.dueAt;
      if (sid == null || due == null) continue;
      (map[sid] ??= <DateTime>{}).add(_dateOnly(due));
    }
    return map;
  }

  // ── 내부 ──────────────────────────────────────────────────────────────────

  static Todo _instanceFor(
    Todo master,
    DateTime occLocalDate,
    String id,
    DateTime now,
  ) {
    final dueAt = _withDate(master.dueAt!, occLocalDate);
    DateTime? endAt;
    if (master.endAt != null) {
      // 기간 모드: 마스터의 (endAt - dueAt) 길이를 그대로 보존.
      endAt = dueAt.add(master.endAt!.difference(master.dueAt!));
    }
    final stamp = now.toUtc();
    return Todo(
      id: id,
      title: master.title,
      category: master.category,
      dueAt: dueAt,
      doneAt: null,
      createdAt: stamp,
      updatedAt: stamp,
      // 캘린더는 마스터 RRULE 이 소유한다. 인스턴스에 링크가 남으면 회차마다
      // 이벤트를 갱신·생성하려 들어 캘린더가 중복으로 뒤덮인다.
      calendarEventId: null,
      calendarId: null,
      parentId: master.parentId,
      type: master.type,
      sortOrder: master.sortOrder,
      description: master.description,
      endAt: endAt,
      isAllDay: master.isAllDay,
      timeAnchor: master.timeAnchor,
      seriesId: master.seriesId,
      recurrenceRule: null, // 인스턴스는 규칙 미보유.
      recurrenceEndAt: null,
      isSeriesMaster: false,
    );
  }

  /// [base] 의 시각/타임존(utc 여부)을 유지한 채 날짜만 [localDate] 로 교체.
  static DateTime _withDate(DateTime base, DateTime localDate) {
    final b = base.toLocal();
    final combined = DateTime(
      localDate.year,
      localDate.month,
      localDate.day,
      b.hour,
      b.minute,
      b.second,
      b.millisecond,
    );
    return base.isUtc ? combined.toUtc() : combined;
  }

  static DateTime _dateOnly(DateTime d) {
    final l = d.toLocal();
    return DateTime(l.year, l.month, l.day);
  }
}
