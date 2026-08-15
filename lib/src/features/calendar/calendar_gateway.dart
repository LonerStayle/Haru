import 'package:googleapis/calendar/v3.dart' as gcal;

/// Google Calendar API 호출의 얇은 이음매.
///
/// 기존 [CalendarService] 는 메서드 안에서 직접 `gcal.CalendarApi(client)` 를 만들어
/// **실제 구글 인증 없이는 호출 경로를 한 줄도 테스트할 수 없었다.** 이 인터페이스를
/// 끼워서 동기화 로직(큐 flush · 증분 수신 · echo 차단 · LWW 병합 · 삭제 규칙)을
/// 전부 메모리 fake 위에서 검증한다.
///
/// 구현:
/// - `GoogleCalendarGateway` — 실제 API (`google_calendar_gateway.dart`)
/// - `FakeCalendarGateway` — 테스트용 메모리 구현 (`test/.../fake_calendar_gateway.dart`)
abstract class CalendarGateway {
  /// 사용자가 접근 가능한 캘린더 목록. 설정 화면이 쓰기 1개 + 읽기 N개를 고르는 데 쓴다.
  Future<List<CalendarInfo>> listCalendars();

  /// 이벤트 생성. 생성된 eventId — 서버가 id 를 주지 않으면 null.
  Future<String?> insertEvent(String calendarId, gcal.Event event);

  /// 이벤트 갱신. 대상이 이미 없으면(404/410) **멱등 성공** — 아래 "삭제 계열 멱등" 참조.
  Future<void> updateEvent(String calendarId, String eventId, gcal.Event event);

  /// 이벤트 삭제. 이미 없으면(404/410) **멱등 성공** — 목표 상태가 이미 달성됐다.
  Future<void> deleteEvent(String calendarId, String eventId);

  /// 변경분 수신.
  ///
  /// - [syncToken] 이 있으면 그것만 전달한다 (증분). Calendar API 는 syncToken 과
  ///   시간 범위 파라미터의 동시 사용을 거부하므로 [timeMin] 은 무시된다.
  /// - 없으면 [timeMin] 기준 전체 조회.
  /// - 반복 일정은 **마스터 1건**으로 받는다 (`singleEvents: false`). 개별 회차로
  ///   펼치면 앱에 수백 건이 쏟아진다.
  /// - 삭제 감지를 위해 취소된 이벤트(`status == 'cancelled'`)도 결과에 포함된다.
  /// - 페이지네이션은 게이트웨이가 내부에서 소진한다 — 호출자는 완결된 결과만 본다.
  ///
  /// syncToken 이 만료되면 [CalendarErrorKind.syncTokenExpired] 로 throw 한다.
  Future<EventPage> listChanges(
    String calendarId, {
    String? syncToken,
    DateTime? timeMin,
  });
}

/// 캘린더 목록 항목.
class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.summary,
    this.primary = false,
    this.accessRole = 'reader',
  });

  /// 캘린더 식별자. 이벤트 CRUD 의 `calendarId` 로 그대로 쓴다.
  final String id;

  /// 사용자에게 보일 이름.
  final String summary;

  /// 계정의 기본 캘린더인지. 쓰기 캘린더의 기본 선택값이 된다.
  final bool primary;

  /// Google 의 접근 권한 — `owner` | `writer` | `reader` | `freeBusyReader` | `none`.
  /// 공휴일·구독 캘린더는 `reader` 라, 쓰기를 시도하면 403 이 난다.
  final String accessRole;

  /// 쓰기 캘린더 후보인지. 설정 화면이 쓰기 대상 목록을 이걸로 거른다.
  bool get canWrite => accessRole == 'owner' || accessRole == 'writer';

  @override
  bool operator ==(Object other) =>
      other is CalendarInfo &&
      other.id == id &&
      other.summary == summary &&
      other.primary == primary &&
      other.accessRole == accessRole;

  @override
  int get hashCode => Object.hash(id, summary, primary, accessRole);

  @override
  String toString() =>
      'CalendarInfo($id, $summary, primary: $primary, role: $accessRole)';
}

/// 증분 수신 1회의 **완결된** 결과. 페이지네이션은 게이트웨이가 이미 소진했다.
class EventPage {
  const EventPage({required this.events, this.nextSyncToken});

  /// 이번에 바뀐 이벤트들. 삭제는 `status == 'cancelled'` 인 tombstone 으로 온다.
  final List<gcal.Event> events;

  /// 다음 호출에 넘길 토큰. null 이면 다음 회차도 전체 조회로 간다.
  final String? nextSyncToken;

  @override
  String toString() =>
      'EventPage(${events.length} events, token: $nextSyncToken)';
}

/// 게이트웨이 오류 분류. 호출자는 이 값만 보고 "재인증 / 재시도 / 포기 / 재동기화" 를 고른다.
enum CalendarErrorKind {
  /// 401 · invalid_grant · scope 부족(403 insufficientPermissions).
  /// 재인증 전에는 어떤 재시도도 무의미하다. 큐는 보존하고 설정에 "재연결 필요" 를 띄운다.
  authRequired,

  /// 403 rateLimitExceeded · 429. 지수 백오프 후 같은 요청을 다시 보내면 된다.
  rateLimited,

  /// [CalendarGateway.listChanges] 의 410 — syncToken 만료.
  /// 토큰을 폐기하고 전체 재동기화 1회로 폴백한다.
  ///
  /// **왜 [EventPage] 의 플래그가 아니라 예외인가**: 410 이면 이번 호출은 결과가
  /// 아예 없다. 플래그로 두면 "events 가 비었는데 진짜 변경 없음인지 실패인지" 를
  /// 호출자가 매번 분기해야 하고, 플래그를 빠뜨리면 조용히 "변경 없음" 으로 오해되어
  /// 동기화가 영원히 멈춘다. 예외는 무시할 수 없다.
  syncTokenExpired,

  /// 5xx · 네트워크 단절 · 타임아웃. 잠시 뒤 재시도 가능.
  transient,

  /// 그 외. 같은 요청을 다시 보내도 결과가 같다 — 큐에서 내리고 오류를 보존한다.
  permanent,
}

/// 게이트웨이가 밖으로 내보내는 단일 오류 타입.
///
/// 타입을 잘게 쪼개는 대신 [kind] 로 분류한다 — 호출자가 필요로 하는 분기는
/// "재인증 / 재시도 / 재동기화 / 포기" 넷뿐이고, 그 이상 쪼개면 `on` 절만 늘어난다.
class CalendarGatewayException implements Exception {
  const CalendarGatewayException(this.kind, {this.status, this.message});

  /// 재인증 필요 — 저장된 토큰이 무효하거나 사용자가 동의를 거부했다.
  factory CalendarGatewayException.authRequired([String? message]) =>
      CalendarGatewayException(
        CalendarErrorKind.authRequired,
        status: 401,
        message: message,
      );

  /// 호출량 제한 — 백오프 후 재시도.
  factory CalendarGatewayException.rateLimited([String? message]) =>
      CalendarGatewayException(
        CalendarErrorKind.rateLimited,
        status: 429,
        message: message,
      );

  /// syncToken 만료 — 전체 재동기화로 폴백.
  factory CalendarGatewayException.syncTokenExpired([String? message]) =>
      CalendarGatewayException(
        CalendarErrorKind.syncTokenExpired,
        status: 410,
        message: message,
      );

  /// 일시 장애 — 재시도.
  factory CalendarGatewayException.transient([String? message]) =>
      CalendarGatewayException(
        CalendarErrorKind.transient,
        status: 503,
        message: message,
      );

  /// 영구 실패 — 재시도 무의미.
  factory CalendarGatewayException.permanent([String? message]) =>
      CalendarGatewayException(CalendarErrorKind.permanent, message: message);

  final CalendarErrorKind kind;

  /// 원본 HTTP 상태. 네트워크 오류처럼 상태가 없으면 null.
  final int? status;

  final String? message;

  /// 백오프 후 같은 요청을 다시 보낼 가치가 있는가.
  bool get isRetryable =>
      kind == CalendarErrorKind.rateLimited ||
      kind == CalendarErrorKind.transient;

  @override
  String toString() =>
      'CalendarGatewayException(${kind.name}, status: $status, message: $message)';
}
