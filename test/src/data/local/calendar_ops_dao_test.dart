import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';

/// CalendarOpsDao 검증 — enqueue / dueOps(백오프 필터) / bumpAttempt /
/// removeById / clear / watchCount.
///
/// 매 테스트는 in-memory AppDatabase 로 fresh start.
void main() {
  group('CalendarOpsDao', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.memory());

    tearDown(() async {
      await db.close();
    });

    CalendarOpRow make({
      required String id,
      String kind = 'create',
      String todoId = 't1',
      String? eventId,
      String calendarId = 'primary',
      String? payload,
      int attempts = 0,
      String? lastError,
      DateTime? nextAttemptAt,
      DateTime? createdAt,
    }) {
      return CalendarOpRow(
        id: id,
        kind: kind,
        todoId: todoId,
        eventId: eventId,
        calendarId: calendarId,
        payload: payload,
        attempts: attempts,
        lastError: lastError,
        nextAttemptAt: nextAttemptAt,
        createdAt: createdAt ?? DateTime.utc(2026, 8, 15, 9),
      );
    }

    test('enqueue + dueOps — createdAt asc(FIFO) 로 반환', () async {
      await db.calendarOpsDao.enqueue(
        make(id: 'op-2', createdAt: DateTime.utc(2026, 8, 15, 9, 1)),
      );
      await db.calendarOpsDao.enqueue(
        make(id: 'op-1', createdAt: DateTime.utc(2026, 8, 15, 9, 0)),
      );

      final due = await db.calendarOpsDao.dueOps(DateTime.utc(2026, 8, 15, 10));
      expect(due.map((r) => r.id).toList(), ['op-1', 'op-2']);
    });

    test('dueOps — nextAttemptAt 이 now 이후면 제외 (백오프)', () async {
      await db.calendarOpsDao.enqueue(make(id: 'op-ready'));
      await db.calendarOpsDao.enqueue(
        make(id: 'op-backoff', nextAttemptAt: DateTime.utc(2026, 8, 15, 12)),
      );

      final due = await db.calendarOpsDao.dueOps(DateTime.utc(2026, 8, 15, 10));
      expect(due.map((r) => r.id).toList(), ['op-ready']);
    });

    test('dueOps — nextAttemptAt 이 now 와 같으면 포함 (이하 조건)', () async {
      final now = DateTime.utc(2026, 8, 15, 10);
      await db.calendarOpsDao.enqueue(make(id: 'op-exact', nextAttemptAt: now));

      final due = await db.calendarOpsDao.dueOps(now);
      expect(due.map((r) => r.id).toList(), ['op-exact']);
    });

    test('bumpAttempt — 재시도 카운트 / 오류 / 다음 시도 시각 갱신', () async {
      await db.calendarOpsDao.enqueue(make(id: 'op-x'));

      await db.calendarOpsDao.bumpAttempt(
        'op-x',
        attempts: 3,
        lastError: 'rate limited',
        nextAttemptAt: DateTime.utc(2026, 8, 15, 11),
      );

      // 아직 백오프 중이므로 이른 now 로는 due 에 안 잡힘.
      final notYetDue = await db.calendarOpsDao.dueOps(
        DateTime.utc(2026, 8, 15, 10, 30),
      );
      expect(notYetDue, isEmpty);

      final due = await db.calendarOpsDao.dueOps(DateTime.utc(2026, 8, 15, 12));
      final row = due.single;
      expect(row.attempts, 3);
      expect(row.lastError, 'rate limited');
      expect(row.nextAttemptAt, DateTime.utc(2026, 8, 15, 11));
    });

    test('removeById — 완료 처리 후 큐에서 제거', () async {
      await db.calendarOpsDao.enqueue(make(id: 'op-done'));
      expect(await db.calendarOpsDao.watchCount().first, 1);

      final deleted = await db.calendarOpsDao.removeById('op-done');
      expect(deleted, 1);
      expect(await db.calendarOpsDao.watchCount().first, 0);
    });

    test('removeById — 없는 id 는 0 반환 (예외 없음)', () async {
      final deleted = await db.calendarOpsDao.removeById('no-such-id');
      expect(deleted, 0);
    });

    test('clear — 큐 전체 비움', () async {
      await db.calendarOpsDao.enqueue(make(id: 'op-a'));
      await db.calendarOpsDao.enqueue(make(id: 'op-b'));
      expect(await db.calendarOpsDao.watchCount().first, 2);

      await db.calendarOpsDao.clear();
      expect(await db.calendarOpsDao.watchCount().first, 0);
    });

    test('watchCount — mutation 마다 emit', () async {
      expect(await db.calendarOpsDao.watchCount().first, 0);

      await db.calendarOpsDao.enqueue(make(id: 'op-1'));
      expect(await db.calendarOpsDao.watchCount().first, 1);

      await db.calendarOpsDao.enqueue(make(id: 'op-2'));
      expect(await db.calendarOpsDao.watchCount().first, 2);

      await db.calendarOpsDao.removeById('op-1');
      expect(await db.calendarOpsDao.watchCount().first, 1);
    });

    test('enqueue — 같은 id 면 update (attempts 갱신, insert 아님)', () async {
      await db.calendarOpsDao.enqueue(make(id: 'op-dup', attempts: 0));
      await db.calendarOpsDao.enqueue(make(id: 'op-dup', attempts: 5));

      final due = await db.calendarOpsDao.dueOps(DateTime.utc(2026, 8, 15, 10));
      expect(due, hasLength(1));
      expect(due.single.attempts, 5);
    });
  });
}
