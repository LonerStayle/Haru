import 'package:solo_todo/src/features/calendar/calendar_event.dart';
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
/// **provider 중립**이라 구글/Microsoft 어느 쪽으로도 세울 수 있다
/// ([FakeCalendarGateway.new] 의 `provider` 인자). 동기화 로직은 게이트웨이가
/// 어느 서비스인지만 알면 되므로, 두 서비스 병존 시나리오도 이 fake 두 개로 검증한다.
///
/// 실제 캘린더 API 의 관찰 가능한 동작을 흉내낸다:
/// - 삭제는 이벤트를 지우는 게 아니라 [CalEvent.cancelled] **tombstone** 으로 남고,
///   증분 조회가 그걸 알려준다 (앱이 삭제를 감지하는 유일한 경로).
/// - `syncToken` 은 "발급 시점 이후 바뀐 것만" 돌려준다 (단조 증가 리비전).
/// - 없는 이벤트에 대한 update/delete 는 404/410 → **멱등 성공**.
class FakeCalendarGateway implements CalendarGateway {
  FakeCalendarGateway({
    List<CalendarInfo>? calendars,
    DateTime Function()? now,
    this.provider = CalendarProvider.google,
  }) : calendars = List.of(calendars ?? _defaultCalendars),
       _now = now ?? (() => DateTime.now().toUtc());

  static const _defaultCalendars = [
    CalendarInfo(
      id: 'primary',
      summary: '기본 캘린더',
      primary: true,
      accessRole: 'owner',
    ),
  ];

  @override
  final CalendarProvider provider;

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
  Future<String?> insertEvent(String calendarId, CalEvent event) async {
    _enter(CalendarOp.insertEvent);
    final id = event.id ?? 'evt-${++_idSeq}';
    _put(calendarId, _stamp(event, id));
    return id;
  }

  @override
  Future<void> updateEvent(
    String calendarId,
    String eventId,
    CalEvent event,
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
          .map((s) => s.event)
          .toList(),
      nextSyncToken: _issueToken(),
    );
  }

  // --- 테스트 상태 구성 (arrange) ------------------------------------------------

  /// 캘린더 쪽에 이미 있던 이벤트를 심는다. **앱 호출로 세지 않고** 오류 주입도 타지 않는다
  /// — 수신(pull) 테스트의 사전 상태를 만드는 용도.
  void seedEvent(String calendarId, CalEvent event) {
    final id = event.id ?? 'evt-${++_idSeq}';
    _put(calendarId, _stamp(event, id));
  }

  /// 캘린더 쪽에서 일정이 삭제된 상황을 흉내낸다 (앱이 지운 게 아님).
  /// 다음 [listChanges] 가 [CalEvent.cancelled] 로 알려준다.
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
  List<CalEvent> liveEvents(String calendarId) =>
      (_store[calendarId]?.values ?? const <_StoredEvent>[])
          .where((s) => !s.event.cancelled)
          .map((s) => s.event)
          .toList();

  /// 단건 조회 — tombstone 도 돌려준다 (삭제 여부는 [CalEvent.cancelled] 로 판단).
  CalEvent? eventById(String calendarId, String eventId) =>
      _store[calendarId]?[eventId]?.event;

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
    return (s == null || s.event.cancelled) ? null : s;
  }

  void _put(String calendarId, CalEvent event) {
    _store.putIfAbsent(calendarId, () => {})[event.id!] = _StoredEvent(
      event,
      ++_rev,
    );
  }

  /// 서버가 채워주는 필드를 흉내낸다. 호출자가 이미 지정한 값은 존중한다
  /// (LWW 테스트가 `updated` 를 직접 고정할 수 있어야 한다).
  ///
  /// [CalEvent] 는 불변이라 저장·반환에 복사가 따로 필요 없다 — 예전 fake 가 JSON
  /// 왕복으로 하던 깊은 복사가 통째로 사라졌다.
  CalEvent _stamp(CalEvent event, String id) =>
      event.copyWith(id: id, updated: event.updated ?? _now());

  CalEvent _tombstone(String eventId) =>
      CalEvent(id: eventId, cancelled: true, updated: _now());

  String _issueToken() {
    final token = 'sync-$_rev';
    _validTokens.add(token);
    return token;
  }

  int _revOf(String token) => int.parse(token.split('-').last);

  /// 실제 API 의 `timeMin` 은 "이벤트 **종료** 시각이 timeMin 이후" 를 뜻한다.
  bool _withinTimeMin(CalEvent event, DateTime? timeMin) {
    if (timeMin == null) return true;
    final end = event.end?.value ?? event.start?.value;
    // 시각을 모르는 이벤트(tombstone 등)는 거르지 않는다 — 삭제를 놓치면 안 된다.
    if (end == null) return true;
    return end.toUtc().isAfter(timeMin.toUtc());
  }
}

class _StoredEvent {
  _StoredEvent(this.event, this.rev);

  final CalEvent event;

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
