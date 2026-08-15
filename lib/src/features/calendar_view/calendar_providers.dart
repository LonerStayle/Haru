import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/day_boundary_provider.dart';
import '../../data/providers.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart';
import '../category/categories_controller.dart';
import '../outline/tree_providers.dart';
import 'calendar_entry.dart';
import 'calendar_layout.dart';

/// 캘린더가 한 화면에 그리는 날짜 구간 (그리드 42칸의 양 끝, date-only, 양쪽 포함).
///
/// `Provider.family` 의 키로 쓰이므로 값 동등성이 필수다 — 같은 달을 다시 그릴 때
/// 새 provider 인스턴스가 생기면 캐시가 매번 날아간다.
class CalendarRange {
  CalendarRange(DateTime start, DateTime end)
    : start = dateOnly(start),
      end = dateOnly(end);

  /// [month] 가 속한 달의 6주 그리드 전체를 덮는 범위.
  factory CalendarRange.forMonth(DateTime month) {
    final days = monthGridDays(month);
    return CalendarRange(days.first, days.last);
  }

  final DateTime start;
  final DateTime end;

  @override
  bool operator ==(Object other) =>
      other is CalendarRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'CalendarRange($start~$end)';
}

/// 캘린더에 그릴 엔트리 — 실제 [Todo] + 미래 반복 고스트.
///
/// 구글 이벤트는 조회가 비동기라 별도 provider 로 두고 화면에서 합친다.
///
/// 순수 함수로 뽑은 이유: 날짜 필터·마스터 제외·고스트 합성이 캘린더 정확도의 전부라
/// 위젯 없이 단위 테스트로 못 박아야 한다.
List<CalendarEntry> buildCalendarEntries({
  required List<Todo> all,
  required Set<String> archivedIds,
  required CalendarRange range,
  required DateTime now,
}) {
  final out = <CalendarEntry>[];

  for (final t in all) {
    // 반복 마스터는 숨김 템플릿이다. allTodosProvider 는 이걸 걸러주지 않으므로
    // (타임라인·전체보기도 안 거르는 기존 결함) 캘린더는 직접 막는다 —
    // 안 그러면 anchor 날짜에 유령 항목이 하나 더 뜬다.
    if (t.isSeriesMaster) continue;
    if (t.dueAt == null) continue;
    if (archivedIds.contains(t.category.id)) continue;
    out.add(TodoEntry(t));
  }

  out.addAll(
    buildRecurringGhosts(
      all: all,
      archivedIds: archivedIds,
      range: range,
      now: now,
    ),
  );
  return out;
}

/// 범위 안의 **미래** 반복 회차를 고스트로 만든다.
///
/// 과거~오늘 회차는 `RecurrenceMaterializer` 가 이미 실제 row 로 만들어 두므로
/// 여기서 만들면 같은 날에 두 개가 겹쳐 보인다. 그래서 오늘 이후만 합성하고,
/// 이미 실체가 있는 날짜(사용자가 미리 건드려 실체화한 회차)도 제외한다.
List<RecurringGhostEntry> buildRecurringGhosts({
  required List<Todo> all,
  required Set<String> archivedIds,
  required CalendarRange range,
  required DateTime now,
}) {
  final masters = RecurrenceMaterializer.activeMasters(all);
  if (masters.isEmpty) return const [];

  final existing = RecurrenceMaterializer.indexExistingInstanceDates(all);
  final today0 = dateOnly(now);
  final out = <RecurringGhostEntry>[];

  for (final m in masters) {
    if (archivedIds.contains(m.category.id)) continue;
    final rule = m.recurrence;
    final anchor = m.dueAt;
    final seriesId = m.seriesId;
    if (rule == null || anchor == null || seriesId == null) continue;

    // 시작점: 범위 시작 / anchor / 오늘 다음날 중 가장 늦은 날.
    var cursor = range.start;
    final anchor0 = dateOnly(anchor);
    if (cursor.isBefore(anchor0)) cursor = anchor0;
    final tomorrow = DateTime(today0.year, today0.month, today0.day + 1);
    if (cursor.isBefore(tomorrow)) cursor = tomorrow;

    // 끝점: 범위 끝과 반복 종료일 중 이른 날.
    var last = range.end;
    final end = m.recurrenceEndAt;
    if (end != null) {
      final end0 = dateOnly(end);
      if (end0.isBefore(last)) last = end0;
    }

    final taken = existing[seriesId] ?? const <DateTime>{};
    while (!cursor.isAfter(last)) {
      if (!taken.contains(cursor) && rule.isOccurrenceOn(cursor, anchor)) {
        out.add(RecurringGhostEntry(master: m, date: cursor));
      }
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
  }
  return out;
}

/// "날짜 없음" 서랍 목록 — 아직 일정으로 옮기지 않은 할 일.
///
/// 제외 규칙과 이유:
/// - 완료된 것 — 이제 와서 일정으로 옮길 이유가 없다.
/// - 메모(note) — 이 서랍의 목적이 "할 일을 달력으로 끌어다 놓기" 라서.
/// - 반복 마스터 — 전 앱 불변 규칙 (숨김 템플릿).
/// - 보관 카테고리 — 다른 화면들과 동일.
List<Todo> buildUndatedTodos({
  required List<Todo> all,
  required Set<String> archivedIds,
}) {
  final out = all
      .where(
        (t) =>
            t.dueAt == null &&
            !t.isSeriesMaster &&
            t.type == TodoType.task &&
            !t.isDone &&
            !archivedIds.contains(t.category.id),
      )
      .toList();
  // 전 앱 공통 정렬 — updatedAt 은 키에 넣지 않는다 (체크·동기화로 자리가 튄다).
  out.sort((a, b) {
    final bySort = a.sortOrder.compareTo(b.sortOrder);
    if (bySort != 0) return bySort;
    final byCreated = b.createdAt.compareTo(a.createdAt);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  });
  return out;
}

/// 캘린더 엔트리 (로컬 Todo + 미래 반복 고스트) — 보이는 달 범위 기준.
///
/// base [allTodosProvider] 는 건드리지 않고 파생 [Provider] 에서 필터만 얹는다.
/// (StreamProvider 를 직접 손대면 보관 집합·범위 변화마다 재구독이 나서 테스트가
/// 정착하지 못한다 — `today_providers.dart` 의 확립된 관용구.)
final calendarEntriesProvider = Provider.family
    .autoDispose<AsyncValue<List<CalendarEntry>>, CalendarRange>((ref, range) {
      // 자정을 넘기면 "오늘 이후" 경계가 바뀌므로 고스트를 다시 계산해야 한다.
      ref.watch(currentDayProvider);
      // 참고: 과거~오늘 회차의 실체화(recurrenceMaterializerProvider)는 화면이 watch
      // 한다 — HomeScreen 과 같은 규약. 여기서 걸면 이 provider 를 쓰는 모든 테스트가
      // DB 를 띄워야 해서, 순수 계산 검증이 무거워진다.
      final all = ref.watch(allTodosProvider);
      final archived = ref.watch(archivedCategoryIdsProvider);
      final now = ref.watch(nowProvider);

      return all.whenData(
        (todos) => buildCalendarEntries(
          all: todos,
          archivedIds: archived,
          range: range,
          now: now(),
        ),
      );
    });

/// 보이는 달의 날짜별 버킷. 각 리스트는 `compareEntries` 순서로 정렬돼 있다.
final calendarBucketsProvider = Provider.family
    .autoDispose<AsyncValue<Map<DateTime, List<CalendarEntry>>>, CalendarRange>(
      (ref, range) {
        final entries = ref.watch(calendarEntriesProvider(range));
        return entries.whenData(
          (list) => bucketByDate(
            entries: list,
            rangeStart: range.start,
            rangeEnd: range.end,
          ),
        );
      },
    );

/// "날짜 없음" 서랍 목록.
final calendarUndatedTodosProvider = Provider<AsyncValue<List<Todo>>>((ref) {
  final all = ref.watch(allTodosProvider);
  final archived = ref.watch(archivedCategoryIdsProvider);
  return all.whenData(
    (todos) => buildUndatedTodos(all: todos, archivedIds: archived),
  );
});
