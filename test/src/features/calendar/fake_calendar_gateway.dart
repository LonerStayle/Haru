import 'dart:convert';

import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';

/// [CalendarGateway] 의 연산 종류. 오류를 특정 연산에만 주입하거나
/// (예: insert 만 429, listChanges 는 정상) 호출 횟수를 확인할 때 쓴다.
enum CalendarOp {
  listCalendars,
  insertEvent,
  updateEvent,
  deleteEvent,
  listChanges,
}

/// 메모리 [CalendarGateway] — 동기화 테스트 전부가 이 위에서 돈다.
///
/// 실제 Calendar API 의 관찰 가능한 동작을 흉내낸다:
/// - 삭제는 이벤트를 지우는 게 아니라 `status == 'cancelled'` **tombstone** 으로 남고,
///   증분 조회가 그걸 알려준다 (앱이 삭제를 감지하는 유일한 경로).
/// - `syncToken` 은 "발급 시점 이후 바뀐 것만" 돌려준다 (단조 증가 리비전).
/// - 없는 이벤트에 대한 update/delete 는 404/410 → **멱등 성공**.
/// - 저장은 항상 복사본 — 호출자가 나중에 이벤트 객체를 바꿔도 저장분은 안 변한다.
class FakeCalendarGateway implements CalendarGateway {
  FakeCalendarGateway({List<CalendarInfo>? calendars, DateTime Function()? now})
    : calendars = List.of(calendars ?? _defaultCalendars),
      _now = now ?? (() => DateTime.now().toUtc());

  static const _defaultCalendars = [
    CalendarInfo(
      id: 'primary',
      summary: '기본 캘린더',
      primary: true,
      accessRole: 'owner',
    ),
  ];

  /// [listCalendars] 가 돌려줄 목록. 테스트가 직접 갈아끼울 수 있다.
  final List<CalendarInfo> calendars;

  final DateTime Function() _now;

  /// calendarId → (eventId → 저장 항목). tombstone 도 여기 남는다.
  final Map<String, Map<String, _StoredEvent>> _store = {};

  /// 단조 증가 리비전. 쓰기 1회마다 1 오른다. syncToken 이 이 값을 가리킨다.
  int _rev = 0;

  /// 자동 부여 eventId 시퀀스.
  int _idSeq = 0;

  /// 발급했고 아직 유효한 토큰들. [expireSyncTokens] 로 한꺼번에 무효화한다.
  /// (모르는 토큰 = 만료된 토큰으로 취급 — 실제 API 도 410 을 준다.)
  final Set<String> _validTokens = {};

  final Map<CalendarOp, int> _callCounts = {};
  final List<_InjectedFailure> _failures = [];

  // --- CalendarGateway -------------------------------------------------------

  @override
  Future<List<CalendarInfo>> listCalendars() async {
    _enter(CalendarOp.listCalendars);
    return List.of(calendars);
  }

  @override
  Future<String?> insertEvent(String calendarId, gcal.Event event) async {
    _enter(CalendarOp.insertEvent);
    final id = event.id ?? 'evt-${++_idSeq}';
    _put(calendarId, _stamp(event, id));
    return id;
  }

  @override
  Future<void> updateEvent(
    String calendarId,
    String eventId,
    gcal.Event event,
  ) async {
    _enter(CalendarOp.updateEvent);
    // 없거나 이미 취소된 이벤트 → 404/410. 멱등 성공이되 **되살리지는 않는다**.
    if (_liveOrNull(calendarId, eventId) == null) return;
    _put(calendarId, _stamp(event, eventId));
  }

  @override
  Future<void> deleteEvent(String calendarId, String eventId) async {
    _enter(CalendarOp.deleteEvent);
    if (_liveOrNull(calendarId, eventId) == null) return; // 이미 없음 — 멱등
    _put(calendarId, _tombstone(eventId));
  }

  @override
  Future<EventPage> listChanges(
    String calendarId, {
    String? syncToken,
    DateTime? timeMin,
  }) async {
    _enter(CalendarOp.listChanges);

    var since = 0;
    if (syncToken != null) {
      if (!_validTokens.contains(syncToken)) {
        throw CalendarGatewayException.syncTokenExpired('만료된 토큰: $syncToken');
      }
      since = _revOf(syncToken);
    }

    final stored = _store[calendarId]?.values ?? const <_StoredEvent>[];
    final changed = stored.where((s) => s.rev > since).toList()
      ..sort((a, b) => a.rev.compareTo(b.rev));

    return EventPage(
      events: changed
          // timeMin 은 전체 조회에만 적용된다 — 증분 모드에선 실제 API 도 무시한다.
          .where((s) => syncToken != null || _withinTimeMin(s.event, timeMin))
          .map((s) => _clone(s.event))
          .toList(),
      nextSyncToken: _issueToken(),
    );
  }

  // --- 테스트 상태 구성 (arrange) ------------------------------------------------

  /// 구글 쪽에 이미 있던 이벤트를 심는다. **앱 호출로 세지 않고** 오류 주입도 타지 않는다
  /// — 수신(pull) 테스트의 사전 상태를 만드는 용도.
  void seedEvent(String calendarId, gcal.Event event) {
    final id = event.id ?? 'evt-${++_idSeq}';
    _put(calendarId, _stamp(event, id));
  }

  /// 구글 쪽에서 일정이 삭제된 상황을 흉내낸다 (앱이 지운 게 아님).
  /// 다음 [listChanges] 가 `status == 'cancelled'` 로 알려준다.
  void cancelRemotely(String calendarId, String eventId) {
    if (_liveOrNull(calendarId, eventId) == null) return;
    _put(calendarId, _tombstone(eventId));
  }

  /// 발급된 모든 syncToken 을 무효화한다 — 다음 증분 조회가
  /// [CalendarErrorKind.syncTokenExpired] 로 실패해 전체 재동기화 폴백을 검증할 수 있다.
  void expireSyncTokens() => _validTokens.clear();

  // --- 오류 주입 ---------------------------------------------------------------

  /// 다음 호출 [times] 회를 [error] 로 실패시킨다.
  /// [op] 를 주면 그 연산만, 없으면 아무 연산이나 매칭된다.
  void failNext(
    CalendarGatewayException error, {
    CalendarOp? op,
    int times = 1,
  }) {
    if (times <= 0) return;
    _failures.add(_InjectedFailure(error, op: op, remaining: times));
  }

  /// [clearFailures] 전까지 계속 실패시킨다.
  void failAlways(CalendarGatewayException error, {CalendarOp? op}) {
    _failures.add(_InjectedFailure(error, op: op, sticky: true));
  }

  void clearFailures() => _failures.clear();

  /// [op] 가 호출된 횟수. 실패로 끝난 호출도 "게이트웨이를 불렀다" 로 센다
  /// (echo 차단 검증은 "아예 안 불렀는가" 를 보므로 이 편이 맞다).
  int callCount(CalendarOp op) => _callCounts[op] ?? 0;

  // --- 저장소 조회 --------------------------------------------------------------

  /// 살아있는(취소되지 않은) 이벤트들.
  List<gcal.Event> liveEvents(String calendarId) =>
      (_store[calendarId]?.values ?? const <_StoredEvent>[])
          .where((s) => s.event.status != 'cancelled')
          .map((s) => _clone(s.event))
          .toList();

  /// 단건 조회 — tombstone 도 돌려준다 (삭제 여부는 `status` 로 판단).
  gcal.Event? eventById(String calendarId, String eventId) {
    final s = _store[calendarId]?[eventId];
    return s == null ? null : _clone(s.event);
  }

  // --- 내부 ------------------------------------------------------------------

  void _enter(CalendarOp op) {
    _callCounts[op] = (_callCounts[op] ?? 0) + 1;
    final i = _failures.indexWhere((f) => f.op == null || f.op == op);
    if (i < 0) return;
    final f = _failures[i];
    if (!f.sticky && --f.remaining <= 0) _failures.removeAt(i);
    throw f.error;
  }

  /// 취소되지 않은 이벤트만 돌려준다. 없거나 tombstone 이면 null (= 404/410).
  _StoredEvent? _liveOrNull(String calendarId, String eventId) {
    final s = _store[calendarId]?[eventId];
    return (s == null || s.event.status == 'cancelled') ? null : s;
  }

  void _put(String calendarId, gcal.Event event) {
    _store.putIfAbsent(calendarId, () => {})[event.id!] = _StoredEvent(
      event,
      ++_rev,
    );
  }

  /// 서버가 채워주는 필드를 흉내낸다. 호출자가 이미 지정한 값은 존중한다
  /// (LWW 테스트가 `updated` 를 직접 고정할 수 있어야 한다).
  gcal.Event _stamp(gcal.Event event, String id) => _clone(event)
    ..id = id
    ..status ??= 'confirmed'
    ..updated ??= _now();

  gcal.Event _tombstone(String eventId) =>
      gcal.Event(id: eventId, status: 'cancelled', updated: _now());

  /// 저장/반환 시 항상 깊은 복사 — fake 내부 상태와 테스트 쪽 객체가 aliasing 되지 않게.
  ///
  /// `Event.toJson()` 은 중첩 객체를 그대로 담아 두고 `jsonEncode` 가 풀도록 되어 있어,
  /// 진짜 map 을 얻으려면 JSON 왕복이 필요하다. 덤으로 `dateTime` 이 실제 API 응답처럼
  /// UTC 로 정규화된다.
  gcal.Event _clone(gcal.Event event) =>
      gcal.Event.fromJson(jsonDecode(jsonEncode(event)) as Map);

  String _issueToken() {
    final token = 'sync-$_rev';
    _validTokens.add(token);
    return token;
  }

  int _revOf(String token) => int.parse(token.split('-').last);

  /// 실제 API 의 `timeMin` 은 "이벤트 **종료** 시각이 timeMin 이후" 를 뜻한다.
  bool _withinTimeMin(gcal.Event event, DateTime? timeMin) {
    if (timeMin == null) return true;
    final end =
        event.end?.dateTime ??
        event.end?.date ??
        event.start?.dateTime ??
        event.start?.date;
    // 시각을 모르는 이벤트(tombstone 등)는 거르지 않는다 — 삭제를 놓치면 안 된다.
    if (end == null) return true;
    return end.toUtc().isAfter(timeMin.toUtc());
  }
}

class _StoredEvent {
  _StoredEvent(this.event, this.rev);

  final gcal.Event event;

  /// 이 이벤트가 마지막으로 쓰인 시점의 리비전. syncToken 비교 기준.
  final int rev;
}

class _InjectedFailure {
  _InjectedFailure(
    this.error, {
    this.op,
    this.remaining = 1,
    this.sticky = false,
  });

  final CalendarGatewayException error;

  /// null 이면 모든 연산에 매칭.
  final CalendarOp? op;

  int remaining;
  final bool sticky;
}
