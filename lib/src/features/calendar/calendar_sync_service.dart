// foundation 전체를 들이면 그쪽 `Category` 가 도메인 `Category` 와 충돌한다.
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:googleapis/calendar/v3.dart' as gcal;

import '../../data/local/app_database.dart';
import '../../data/local/calendar_ops_dao.dart';
import '../../data/todo_repository.dart';
import '../../domain/category.dart';
import '../../domain/todo.dart';
import 'calendar_gateway.dart';
import 'calendar_merge.dart';
import 'calendar_service.dart';
import 'calendar_settings.dart';
import 'event_import_filter.dart';
import 'event_to_todo.dart';

/// 큐 한 번 비우기의 결과. 설정 화면이 상태를 보여주는 데 쓴다.
class PushResult {
  const PushResult({
    this.succeeded = 0,
    this.retryable = 0,
    this.dropped = 0,
    this.authRequired = false,
  });

  /// 구글에 반영된 항목 수.
  final int succeeded;

  /// 실패했지만 큐에 남아 다시 시도될 항목 수.
  final int retryable;

  /// 더 할 일이 없어 큐에서 내린 항목 수 (대상이 사라졌거나 재시도 상한 초과).
  final int dropped;

  /// 재인증이 필요해 중단됐는가. 설정 화면이 "다시 연결" 을 띄운다.
  final bool authRequired;

  @override
  String toString() =>
      'PushResult(성공 $succeeded, 재시도 $retryable, 폐기 $dropped, '
      '재인증 필요 $authRequired)';
}

/// 수신 1회의 결과.
class PullResult {
  const PullResult({
    this.imported = 0,
    this.updated = 0,
    this.deleted = 0,
    this.unlinked = 0,
    this.skipped = 0,
    this.authRequired = false,
    this.newSyncTokens = const {},
    this.expiredCalendars = const {},
  });

  /// 캘린더에서 새로 들어온 할 일 수.
  final int imported;

  /// 캘린더 쪽 수정이 반영된 할 일 수.
  final int updated;

  /// 캘린더에서 지워져 함께 삭제된 할 일 수 (유입 항목).
  final int deleted;

  /// 캘린더에서 지워졌지만 할 일은 남기고 연결만 끊은 수 (앱이 만든 항목).
  final int unlinked;

  /// 필터에 걸려 들이지 않은 이벤트 수.
  final int skipped;

  final bool authRequired;

  /// 캘린더 id → 다음 회차에 쓸 토큰. 호출자가 설정에 저장한다.
  final Map<String, String> newSyncTokens;

  /// 토큰이 만료돼 전체 재수집으로 폴백한 캘린더들.
  final Set<String> expiredCalendars;

  @override
  String toString() =>
      'PullResult(유입 $imported, 갱신 $updated, 삭제 $deleted, '
      '연결해제 $unlinked, 건너뜀 $skipped)';
}

/// 앱 → 캘린더 방향의 실행부. 큐에 쌓인 작업을 구글에 반영한다.
///
/// 기존 Supabase outbox 와 달리 **항목이 서로 독립**이다. 하나가 실패해도 나머지를
/// 계속 진행한다 — 캘린더 작업은 서로 순서 의존이 없고, 한 건의 rate limit 때문에
/// 나머지 전부가 막히면 사용자는 "동기화가 죽었다" 고 느낀다.
///
/// 예외는 재인증뿐이다. 토큰이 무효한 상태에서는 어떤 재시도도 무의미하므로 즉시
/// 멈추고 큐를 그대로 보존한다.
class CalendarSyncService {
  CalendarSyncService({
    required this.gateway,
    required this.ops,
    required this.repo,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CalendarGateway gateway;
  final CalendarOpsDao ops;
  final TodoRepository repo;
  final DateTime Function() _now;

  /// 재시도 상한. 넘으면 큐에서 내리고 마지막 오류만 남긴다 —
  /// 고칠 수 없는 작업이 큐에 영원히 남아 매 동기화를 지연시키는 것을 막는다.
  static const maxAttempts = 5;

  /// 시도 횟수별 대기 시간. rate limit 은 금방 풀리지 않으므로 빠르게 벌린다.
  static const _backoff = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
  ];

  /// 큐를 한 번 비운다. 이미 진행 중이면 중복 실행하지 않는다.
  Future<PushResult> flushPending() async {
    if (_flushing) return const PushResult();
    _flushing = true;
    try {
      return await _doFlush();
    } finally {
      _flushing = false;
    }
  }

  bool _flushing = false;

  Future<PushResult> _doFlush() async {
    final due = await ops.dueOps(_now());
    var succeeded = 0;
    var retryable = 0;
    var dropped = 0;

    for (final op in due) {
      try {
        final handled = await _apply(op);
        await ops.removeById(op.id);
        if (handled) {
          succeeded++;
        } else {
          dropped++;
        }
      } on CalendarGatewayException catch (e) {
        if (e.kind == CalendarErrorKind.authRequired) {
          // 재인증 전에는 남은 항목도 전부 같은 실패다. 큐를 보존하고 즉시 중단.
          return PushResult(
            succeeded: succeeded,
            retryable: retryable,
            dropped: dropped,
            authRequired: true,
          );
        }
        final attempts = op.attempts + 1;
        if (!e.isRetryable || attempts >= maxAttempts) {
          debugPrint('[solo_todo] 캘린더 작업 폐기 (${op.kind}): $e');
          await ops.removeById(op.id);
          dropped++;
        } else {
          await ops.bumpAttempt(
            op.id,
            attempts: attempts,
            lastError: e.toString(),
            nextAttemptAt: _now().add(_backoffFor(attempts)),
          );
          retryable++;
        }
      }
    }

    return PushResult(
      succeeded: succeeded,
      retryable: retryable,
      dropped: dropped,
    );
  }

  Duration _backoffFor(int attempts) =>
      _backoff[(attempts - 1).clamp(0, _backoff.length - 1)];

  /// 작업 1건 실행. 실제로 구글에 뭔가 반영했으면 true, 할 일이 없어졌으면 false.
  Future<bool> _apply(CalendarOpRow op) async {
    // 큐에 쌓인 뒤에도 할 일은 계속 바뀐다 — 스냅샷이 아니라 **지금 상태**를 보낸다.
    final todo = await repo.getById(op.todoId);

    switch (op.kind) {
      case 'delete':
        final eventId = op.eventId;
        if (eventId == null) return false;
        await gateway.deleteEvent(op.calendarId, eventId);
        return true;

      case 'create':
        if (todo == null || todo.dueAt == null) return false;
        // 다른 기기가 먼저 만들었을 수 있다. 그대로 create 하면 이벤트가 둘이 된다.
        final existing = todo.calendarEventId;
        if (existing != null) {
          await gateway.updateEvent(
            todo.calendarId ?? op.calendarId,
            existing,
            _buildEvent(todo),
          );
          return true;
        }
        final created = await gateway.insertEvent(
          op.calendarId,
          _buildEvent(todo),
        );
        if (created != null) await _saveLink(todo, created, op.calendarId);
        return true;

      case 'update':
        final eventId = op.eventId;
        if (eventId == null) return false;
        // 갱신하려는데 할 일이 사라졌다면 이벤트도 남을 이유가 없다.
        if (todo == null || todo.dueAt == null) {
          await gateway.deleteEvent(op.calendarId, eventId);
          return true;
        }
        await gateway.updateEvent(op.calendarId, eventId, _buildEvent(todo));
        return true;

      default:
        return false;
    }
  }

  // ignore: invalid_use_of_visible_for_testing_member
  static gcal.Event _buildEvent(Todo todo) => CalendarService.buildEvent(todo);

  /// 생성된 이벤트 id 를 할 일에 붙인다.
  ///
  /// **`updatedAt` 을 건드리지 않는다.** 이벤트에 심어둔 서명(`haruRev`)이 push 시점의
  /// `updatedAt` 이라, 여기서 시각을 갱신하면 서명과 어긋나 다음 수신에서 자기 변경을
  /// echo 로 인식하지 못한다.
  Future<void> _saveLink(Todo todo, String eventId, String calendarId) => repo
      .upsert(todo.copyWith(calendarEventId: eventId, calendarId: calendarId));

  // ── 캘린더 → 앱 ─────────────────────────────────────────────────────────

  /// 읽기 캘린더들의 변경분을 받아 앱에 반영한다.
  ///
  /// [categoryFor] 는 캘린더 id 로 유입 항목의 카테고리를 정한다 — 설정의 매핑과
  /// 활성 카테고리 목록을 아는 것은 호출자이므로 함수로 주입받는다.
  ///
  /// 새 토큰은 저장하지 않고 [PullResult] 로 돌려준다. 설정 저장은 호출자 몫이라
  /// 이 서비스는 설정 저장소를 몰라도 되고, 테스트도 가벼워진다.
  Future<PullResult> pull({
    required CalendarSettings settings,
    required Category Function(String calendarId) categoryFor,
  }) async {
    if (settings.readCalendarIds.isEmpty) return const PullResult();

    // 링크 조회를 위해 한 번만 전체를 읽는다 — 이벤트마다 DB 를 뒤지지 않기 위함.
    final all = await repo.watchAll().first;
    final byEventId = <String, Todo>{
      for (final t in all)
        if (t.calendarEventId != null) t.calendarEventId!: t,
    };
    final knownTodoIds = all.map((t) => t.id).toSet();

    var imported = 0;
    var updated = 0;
    var deleted = 0;
    var unlinked = 0;
    var skipped = 0;
    final newTokens = <String, String>{};
    final expired = <String>{};

    for (final calendarId in settings.readCalendarIds) {
      EventPage page;
      try {
        page = await _fetchChanges(calendarId, settings.syncTokens[calendarId]);
      } on _SyncTokenExpired {
        expired.add(calendarId);
        try {
          page = await _fetchChanges(calendarId, null);
        } on CalendarGatewayException catch (e) {
          if (e.kind == CalendarErrorKind.authRequired) {
            return PullResult(
              imported: imported,
              updated: updated,
              deleted: deleted,
              unlinked: unlinked,
              skipped: skipped,
              authRequired: true,
              newSyncTokens: newTokens,
              expiredCalendars: expired,
            );
          }
          continue; // 일시 오류 — 다음 회차에 다시.
        }
      } on CalendarGatewayException catch (e) {
        if (e.kind == CalendarErrorKind.authRequired) {
          return PullResult(
            imported: imported,
            updated: updated,
            deleted: deleted,
            unlinked: unlinked,
            skipped: skipped,
            authRequired: true,
            newSyncTokens: newTokens,
            expiredCalendars: expired,
          );
        }
        continue;
      }

      for (final event in page.events) {
        final verdict = judgeImport(
          event,
          importInvited: settings.importInvited,
          knownTodoIds: knownTodoIds,
        );
        final linked = byEventId[event.id];

        if (verdict == ImportVerdict.cancelled) {
          if (linked == null) continue;
          if (linked.calendarOrigin == 'gcal') {
            // 구글이 원본이었다 — 원본이 사라졌으니 할 일도 지운다.
            await repo.deleteById(linked.id);
            deleted++;
          } else {
            // 앱이 원본이다 — 할 일은 대표님 것이므로 남기고 연결만 끊는다.
            await repo.upsert(
              linked.copyWith(calendarEventId: null, calendarId: null),
            );
            unlinked++;
          }
          byEventId.remove(event.id);
          continue;
        }

        if (linked != null) {
          final merge = mergeEventIntoTodo(event: event, local: linked);
          if (merge.kind == MergeKind.updated) {
            await repo.upsert(merge.merged!);
            updated++;
          }
          continue;
        }

        if (!verdict.isAccepted) {
          skipped++;
          continue;
        }

        final created = await _importEvent(event, calendarId, categoryFor);
        if (created == null) {
          skipped++;
        } else {
          imported++;
          byEventId[event.id!] = created;
          knownTodoIds.add(created.id);
        }
      }

      final token = page.nextSyncToken;
      if (token != null) newTokens[calendarId] = token;
    }

    return PullResult(
      imported: imported,
      updated: updated,
      deleted: deleted,
      unlinked: unlinked,
      skipped: skipped,
      newSyncTokens: newTokens,
      expiredCalendars: expired,
    );
  }

  /// 만료 토큰을 [_SyncTokenExpired] 로 바꿔 호출부의 폴백 분기를 단순하게 만든다.
  Future<EventPage> _fetchChanges(String calendarId, String? token) async {
    try {
      return await gateway.listChanges(
        calendarId,
        syncToken: token,
        timeMin: token == null ? _fullSyncFloor() : null,
      );
    } on CalendarGatewayException catch (e) {
      if (e.kind == CalendarErrorKind.syncTokenExpired) {
        throw const _SyncTokenExpired();
      }
      rethrow;
    }
  }

  /// 전체 수집의 과거 방향 하한. 지난 일정까지 통째로 가져오면 첫 동기화가 무거워진다.
  DateTime _fullSyncFloor() =>
      _now().toUtc().subtract(const Duration(days: 30));

  Future<Todo?> _importEvent(
    gcal.Event event,
    String calendarId,
    Category Function(String) categoryFor,
  ) async {
    final patch = eventToTodoPatch(event);
    if (patch == null || patch.dueAt == null) return null;

    final category = categoryFor(calendarId);
    final minSibling = await repo.minSiblingSortOrder(
      categoryId: category.id,
      parentId: null,
    );
    final todo =
        Todo.create(
          title: patch.title,
          category: category,
          dueAt: patch.dueAt,
          now: _now,
          // 방금 들어온 것을 바로 볼 수 있게 맨 위로.
          sortOrder: (minSibling ?? 0) - 1,
          endAt: patch.endAt,
          isAllDay: patch.isAllDay,
          timeAnchor: patch.timeAnchor,
          recurrenceRule: patch.recurrence?.encode(),
          recurrenceEndAt: patch.recurrenceEndAt,
        ).copyWith(
          calendarEventId: event.id,
          calendarId: calendarId,
          // 출처를 기록해야 삭제 규칙이 성립한다 — 구글에서 지워졌을 때
          // 할 일을 함께 지울지, 연결만 끊을지가 이 값으로 갈린다.
          calendarOrigin: 'gcal',
        );
    await repo.upsert(todo);
    return todo;
  }
}

/// 만료 토큰 폴백용 내부 신호.
class _SyncTokenExpired implements Exception {
  const _SyncTokenExpired();
}
