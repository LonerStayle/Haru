import 'package:drift/drift.dart';

import '../../features/calendar/calendar_event.dart';
import 'app_database.dart';

part 'calendar_ops_dao.g.dart';

/// Google Calendar 동기화 push 대기열 DAO.
///
/// [OutboxDao] (Supabase 동기화) 와 구조는 비슷하지만 성질이 다르다 —
/// 항목 간 독립 실패(하나 실패해도 다음 진행) + rate limit 대응 지수 백오프
/// 재시도가 필요해 FIFO 순서 보존을 강제하지 않는다. `attempts` /
/// `nextAttemptAt` / `lastError` 로 재시도 상태를 항목별로 추적한다.
@DriftAccessor(tables: [CalendarOps])
class CalendarOpsDao extends DatabaseAccessor<AppDatabase>
    with _$CalendarOpsDaoMixin {
  CalendarOpsDao(super.db);

  /// id 기준 upsert (없으면 insert, 있으면 전체 update).
  Future<void> enqueue(CalendarOpRow row) {
    return into(calendarOps).insertOnConflictUpdate(
      CalendarOpsCompanion(
        id: Value(row.id),
        kind: Value(row.kind),
        todoId: Value(row.todoId),
        eventId: Value(row.eventId),
        calendarId: Value(row.calendarId),
        provider: Value(row.provider),
        payload: Value(row.payload),
        attempts: Value(row.attempts),
        lastError: Value(row.lastError),
        nextAttemptAt: Value(row.nextAttemptAt),
        createdAt: Value(row.createdAt),
      ),
    );
  }

  /// 재시도 가능한 항목만 `createdAt asc` (FIFO) 로 반환.
  /// `nextAttemptAt` 이 null 이거나 [now] 이하인 항목만 포함 — 지수 백오프 필터.
  ///
  /// [provider] 를 주면 그 서비스 것만 골라낸다. 구글과 Microsoft 를 동시에 켤 수
  /// 있으므로, 한쪽 동기화가 다른 쪽 작업을 집어가면 엉뚱한 API 로 날아간다.
  /// **provider 가 null 인 옛 row 는 구글로 본다** (컬럼이 생기기 전 큐 항목).
  Future<List<CalendarOpRow>> dueOps(
    DateTime now, {
    CalendarProvider? provider,
  }) {
    final q = select(calendarOps)
      ..where(
        (t) =>
            t.nextAttemptAt.isNull() |
            t.nextAttemptAt.isSmallerOrEqualValue(now),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
      ]);
    if (provider == null) return q.get();
    return q.get().then(
      (rows) => rows
          .where((r) => CalendarProvider.fromWire(r.provider) == provider)
          .toList(),
    );
  }

  /// 실패 후 재시도 상태 갱신 — 시도 횟수 / 오류 사유 / 다음 시도 시각(백오프).
  /// 백오프 계산 자체는 호출자(sync 서비스) 책임 — DAO 는 순수 저장만 담당.
  Future<void> bumpAttempt(
    String id, {
    required int attempts,
    String? lastError,
    DateTime? nextAttemptAt,
  }) {
    return (update(calendarOps)..where((t) => t.id.equals(id))).write(
      CalendarOpsCompanion(
        attempts: Value(attempts),
        lastError: Value(lastError),
        nextAttemptAt: Value(nextAttemptAt),
      ),
    );
  }

  Future<int> removeById(String id) =>
      (delete(calendarOps)..where((t) => t.id.equals(id))).go();

  /// 큐 전체 비우기 — signOut / 연결 해제 시 사용.
  Future<void> clear() => delete(calendarOps).go();

  /// 한 서비스의 큐만 비우기 — 한쪽만 연결 해제할 때 다른 쪽 대기열을 날리지 않는다.
  /// (provider 가 null 인 옛 row 는 구글 것으로 본다.)
  Future<void> clearProvider(CalendarProvider provider) async {
    final rows = await select(calendarOps).get();
    for (final row in rows) {
      if (CalendarProvider.fromWire(row.provider) != provider) continue;
      await removeById(row.id);
    }
  }

  /// 큐 길이 변동 stream — 설정 화면 "동기화 대기" indicator 갱신용.
  Stream<int> watchCount() {
    return select(calendarOps).watch().map((rows) => rows.length);
  }
}
