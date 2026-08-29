import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;

import '../../domain/recurrence.dart';
import 'calendar_auth.dart';
import 'calendar_event.dart';
import 'calendar_gateway.dart';

/// Microsoft Graph v1.0.
const _graphBase = 'https://graph.microsoft.com/v1.0';

/// 앱 서명을 실어 나르는 확장 속성의 네임스페이스.
///
/// `PS_PUBLIC_STRINGS` — MAPI 명명 속성의 공개 네임스페이스다. 이름만 정하면
/// 되고 별도 등록이 필요 없어, 그래프에서 사용자 정의 값을 붙이는 가장 가벼운
/// 방법이다.
const _extendedPropertyNamespace = '6ed8da90-450b-101b-98da-00aa003f1305';

/// 이벤트에 실어 보낼 앱 서명 키들. `singleValueExtendedProperties` 는 키를
/// 하나하나 지정해야 해서 목록이 필요하다.
const _appPropertyKeys = [
  'haruTodoId',
  'haruRev',
  'haruDateMode',
  'haruAnchor',
];

/// 한 번에 받아올 이벤트 수 — 응답을 짧게 유지한다.
const _pageSize = 100;

/// 전체(비증분) 조회에서 소진할 페이지 상한. 그래프의 증분 조회는 시간 범위를
/// 받지 못해 첫 회차가 통째로 내려올 수 있다. 무한정 돌지 않게 막는다.
const _maxPages = 50;

/// Microsoft 365(Outlook) 캘린더를 다루는 [CalendarGateway].
///
/// Teams 회의도 결국 Outlook 캘린더의 일정이므로 이 게이트웨이 하나로 커버된다.
///
/// 구글 게이트웨이와 마찬가지로 **그래프 JSON 은 이 파일 안에서 끝난다** — 바깥으로는
/// [CalEvent] 만 나간다. 그래서 큐 flush · 병합 · 삭제 규칙 코드가 그대로 재사용된다.
class MicrosoftGraphGateway implements CalendarGateway {
  MicrosoftGraphGateway(this._auth);

  final CalendarAuth _auth;

  @override
  CalendarProvider get provider => CalendarProvider.microsoft;

  /// 증분 조회에서 확장 속성(`$expand`)을 함께 요청해도 되는가.
  ///
  /// 그래프의 delta 는 `$expand` 지원이 문서상 분명하지 않다. 400 이 돌아오면 이
  /// 플래그를 내리고 확장 없이 다시 부른다 — 그 경우 앱 서명이 비어서 오지만,
  /// 병합 쪽의 "내용이 같으면 echo" + "연결된 할 일의 모드를 힌트로" 규칙이 있어
  /// 동기화 자체는 정상 동작한다.
  bool _expandSupported = true;

  @override
  Future<List<CalendarInfo>> listCalendars() => _withClient((client) async {
    final json = await _getJson(client, Uri.parse('$_graphBase/me/calendars'));
    final value = json['value'];
    if (value is! List) return const <CalendarInfo>[];
    return [
      for (final item in value)
        if (item is Map)
          microsoftCalendarFromJson(item.cast<String, dynamic>()),
    ].whereType<CalendarInfo>().toList();
  });

  @override
  Future<String?> insertEvent(String calendarId, CalEvent event) =>
      _withClient((client) async {
        final res = await client.post(
          Uri.parse('$_graphBase${eventsPath(calendarId)}'),
          headers: _jsonHeaders,
          body: jsonEncode(microsoftEventToJson(event)),
        );
        if (res.statusCode >= 400) {
          throw classifyGraphError(res.statusCode, res.body);
        }
        final json = _decode(res.body);
        final id = json['id'];
        return id is String ? id : null;
      });

  @override
  Future<void> updateEvent(String calendarId, String eventId, CalEvent event) =>
      _withClient((client) async {
        final res = await client.patch(
          Uri.parse('$_graphBase/me/events/${Uri.encodeComponent(eventId)}'),
          headers: _jsonHeaders,
          body: jsonEncode(microsoftEventToJson(event)),
        );
        // 이미 지워진 이벤트 — 계속 재시도해봐야 영영 실패한다. 멱등 성공으로 흘리고
        // 링크 해제는 다음 증분 수신이 tombstone 을 보고 처리한다.
        if (res.statusCode == 404 || res.statusCode == 410) return;
        if (res.statusCode >= 400) {
          throw classifyGraphError(res.statusCode, res.body);
        }
      });

  @override
  Future<void> deleteEvent(String calendarId, String eventId) =>
      _withClient((client) async {
        final res = await client.delete(
          Uri.parse('$_graphBase/me/events/${Uri.encodeComponent(eventId)}'),
        );
        if (res.statusCode == 404 || res.statusCode == 410) return; // 이미 없음
        if (res.statusCode >= 400) {
          throw classifyGraphError(res.statusCode, res.body);
        }
      });

  @override
  Future<EventPage> listChanges(
    String calendarId, {
    String? syncToken,
    DateTime? timeMin,
  }) => _withClient((client) async {
    final events = <CalEvent>[];
    String? deltaLink;

    // 증분이면 저장해 둔 deltaLink 를 그대로 다시 부른다 (그래프의 계약).
    var url = syncToken != null
        ? Uri.parse(syncToken)
        : _deltaUri(calendarId, withExpand: _expandSupported);

    for (var page = 0; page < _maxPages; page++) {
      Map<String, dynamic> json;
      try {
        json = await _getJson(client, url);
      } on CalendarGatewayException catch (e) {
        // 확장 속성 요청이 거부된 첫 회차라면 확장 없이 한 번 더 시도한다.
        final canRetryWithoutExpand =
            syncToken == null &&
            _expandSupported &&
            e.status == 400 &&
            page == 0;
        if (!canRetryWithoutExpand) rethrow;
        _expandSupported = false;
        url = _deltaUri(calendarId, withExpand: false);
        json = await _getJson(client, url);
      }

      final value = json['value'];
      if (value is List) {
        for (final item in value) {
          if (item is Map) {
            events.add(microsoftEventFromJson(item.cast<String, dynamic>()));
          }
        }
      }

      final next = json['@odata.nextLink'];
      final delta = json['@odata.deltaLink'];
      if (delta is String) deltaLink = delta;
      if (next is! String) break;
      url = Uri.parse(next);
    }

    return EventPage(
      // 그래프의 증분 조회는 시간 범위를 받지 못한다 — 전체 회차에서만 앱이 직접
      // 하한을 적용해 오래된 일정이 통째로 쏟아지는 것을 막는다. 취소 tombstone 은
      // 시각이 없으므로 절대 거르지 않는다 (삭제를 놓치면 유령이 남는다).
      events: syncToken == null && timeMin != null
          ? events.where((e) => _endsAfter(e, timeMin)).toList()
          : events,
      nextSyncToken: deltaLink,
    );
  });

  Uri _deltaUri(String calendarId, {required bool withExpand}) {
    final params = <String, String>{r'$top': '$_pageSize'};
    if (withExpand) {
      final filter = _appPropertyKeys
          .map((k) => "id eq '${_extendedPropertyId(k)}'")
          .join(' or ');
      params[r'$expand'] = 'singleValueExtendedProperties(\$filter=$filter)';
    }
    return Uri.parse(
      '$_graphBase${eventsPath(calendarId)}/delta',
    ).replace(queryParameters: params);
  }

  static bool _endsAfter(CalEvent event, DateTime timeMin) {
    if (event.cancelled) return true;
    final end = event.end?.value ?? event.start?.value;
    if (end == null) return true;
    return end.toUtc().isAfter(timeMin.toUtc());
  }

  Map<String, String> get _jsonHeaders => const {
    'Content-Type': 'application/json',
    // 시각을 항상 UTC 로 받아 파싱 규칙을 하나로 유지한다.
    'Prefer': 'outlook.timezone="UTC"',
  };

  Future<Map<String, dynamic>> _getJson(http.Client client, Uri url) async {
    final res = await client.get(
      url,
      headers: const {'Prefer': 'outlook.timezone="UTC"'},
    );
    if (res.statusCode >= 400) {
      throw classifyGraphError(res.statusCode, res.body);
    }
    return _decode(res.body);
  }

  static Map<String, dynamic> _decode(String body) {
    if (body.isEmpty) return const {};
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : const {};
  }

  /// 인증된 client 를 열어 [body] 를 돌리고, 오류를 분류해 다시 던진다.
  /// 사용 후 반드시 close 한다 ([CalendarAuth] 계약).
  Future<T> _withClient<T>(Future<T> Function(http.Client client) body) async {
    final client = await _auth.authedClient();
    if (client == null) {
      throw CalendarGatewayException.authRequired('Microsoft 계정 동의가 없습니다.');
    }
    try {
      return await body(client);
    } on CalendarGatewayException {
      rethrow;
    } catch (e, st) {
      Error.throwWithStackTrace(classifyGraphTransportError(e), st);
    } finally {
      client.close();
    }
  }
}

// ---------------------------------------------------------------------------
// 경로 · 확장 속성 id
// ---------------------------------------------------------------------------

/// 기본 캘린더를 가리키는 sentinel 인가.
///
/// 사용자가 설정에서 캘린더를 고르기 전에는 "계정의 기본 캘린더" 로 동작해야 한다.
/// 구글 쪽 기본값이 `'primary'` 라 같은 값을 함께 받는다.
@visibleForTesting
bool isDefaultMicrosoftCalendar(String calendarId) =>
    calendarId.isEmpty || calendarId == 'primary' || calendarId == 'default';

/// 이벤트 컬렉션 경로. 기본 캘린더면 `/me/events`, 아니면 `/me/calendars/{id}/events`.
@visibleForTesting
String eventsPath(String calendarId) => isDefaultMicrosoftCalendar(calendarId)
    ? '/me/events'
    : '/me/calendars/${Uri.encodeComponent(calendarId)}/events';

String _extendedPropertyId(String name) =>
    'String {$_extendedPropertyNamespace} Name $name';

// ---------------------------------------------------------------------------
// JSON ↔ 중립 DTO (순수 함수 — 네트워크 없이 전부 테스트한다)
// ---------------------------------------------------------------------------

/// 그래프 캘린더 JSON → [CalendarInfo]. id 가 없으면 null.
@visibleForTesting
CalendarInfo? microsoftCalendarFromJson(Map<String, dynamic> json) {
  final id = json['id'];
  if (id is! String || id.isEmpty) return null;
  final name = json['name'];
  return CalendarInfo(
    id: id,
    summary: name is String && name.isNotEmpty ? name : id,
    primary: json['isDefaultCalendar'] == true,
    // 그래프는 owner/writer/reader 를 `canEdit` 한 칸으로 표현한다.
    accessRole: json['canEdit'] == true ? 'owner' : 'reader',
  );
}

/// [CalEvent] → 그래프 이벤트 JSON (생성/갱신 본문).
@visibleForTesting
Map<String, dynamic> microsoftEventToJson(CalEvent event) {
  final isAllDay = event.start?.isAllDay ?? false;
  final json = <String, dynamic>{
    'subject': event.title ?? '',
    'body': {'contentType': 'text', 'content': event.description ?? ''},
    'isAllDay': isAllDay,
  };

  final start = _toGraphTime(event.start);
  final end = _toGraphTime(event.end);
  if (start != null) json['start'] = start;
  if (end != null) json['end'] = end;

  final recurrence = _toGraphRecurrence(event);
  // 반복이 없으면 null 을 명시해 기존 반복을 해제한다 (PATCH 에서 생략하면 유지된다).
  json['recurrence'] = recurrence;

  if (event.appProperties.isNotEmpty) {
    json['singleValueExtendedProperties'] = [
      for (final entry in event.appProperties.entries)
        {'id': _extendedPropertyId(entry.key), 'value': entry.value},
    ];
  }
  return json;
}

/// 그래프 이벤트 JSON → [CalEvent].
///
/// 삭제는 `@removed` 만 담긴 축약 항목으로 오므로 id 외에는 아무것도 없다 —
/// 그래도 [CalEvent.cancelled] 로 정확히 표현된다.
@visibleForTesting
CalEvent microsoftEventFromJson(Map<String, dynamic> json) {
  final removed = json['@removed'] != null;
  final id = json['id'];
  if (removed) {
    return CalEvent(id: id is String ? id : null, cancelled: true);
  }

  final isAllDay = json['isAllDay'] == true;
  final subject = json['subject'];
  final response = json['responseStatus'];

  return CalEvent(
    id: id is String ? id : null,
    title: subject is String ? subject : null,
    description: _bodyText(json),
    start: _fromGraphTime(json['start'], isAllDay: isAllDay),
    end: _fromGraphTime(json['end'], isAllDay: isAllDay),
    cancelled: json['isCancelled'] == true,
    updated: _parseGraphInstant(json['lastModifiedDateTime']),
    recurrence: _fromGraphRecurrence(json['recurrence']),
    appProperties: _appPropertiesFromJson(json),
    // Outlook 은 이벤트 단위 색 지정이 마스터 범주 등록을 요구해 완료 표시를
    // 반영하지 않는다. 되읽을 때도 항상 false 로 둔다.
    markDone: false,
    autoGenerated: false,
    organizerIsSelf: json['isOrganizer'] is bool
        ? json['isOrganizer'] as bool
        : null,
    selfResponseStatus: response is Map && response['response'] is String
        ? response['response'] as String
        : null,
  );
}

String? _bodyText(Map<String, dynamic> json) {
  final body = json['body'];
  if (body is Map && body['content'] is String) {
    final content = (body['content'] as String).trim();
    if (content.isNotEmpty) return content;
  }
  final preview = json['bodyPreview'];
  return preview is String && preview.isNotEmpty ? preview : null;
}

Map<String, String> _appPropertiesFromJson(Map<String, dynamic> json) {
  final props = json['singleValueExtendedProperties'];
  if (props is! List) return const {};
  final out = <String, String>{};
  for (final item in props) {
    if (item is! Map) continue;
    final id = item['id'];
    final value = item['value'];
    if (id is! String || value is! String) continue;
    // 'String {guid} Name haruRev' → 'haruRev'
    final marker = id.lastIndexOf(' Name ');
    if (marker < 0) continue;
    out[id.substring(marker + ' Name '.length)] = value;
  }
  return out;
}

Map<String, dynamic>? _toGraphTime(CalEventTime? time) {
  if (time == null) return null;
  final date = time.date;
  if (date != null) {
    // 종일 이벤트의 양끝은 자정이어야 한다 (그래프의 요구). 종료는 exclusive —
    // DTO 가 이미 그 규칙으로 담고 있다.
    return {'dateTime': '${_ymd(date)}T00:00:00', 'timeZone': 'UTC'};
  }
  final dt = time.dateTime;
  if (dt == null) return null;
  return {
    // timeZone 을 함께 보내므로 오프셋 표기('Z')는 빼야 한다.
    'dateTime': dt.toUtc().toIso8601String().replaceAll('Z', ''),
    'timeZone': 'UTC',
  };
}

CalEventTime? _fromGraphTime(Object? raw, {required bool isAllDay}) {
  if (raw is! Map) return null;
  final value = raw['dateTime'];
  if (value is! String) return null;
  final parsed = _parseGraphInstant(value);
  if (parsed == null) return null;
  if (isAllDay) {
    // 종일은 "어느 날" 만 의미 있다 — 구글의 `start.date` 와 같은 모양(로컬 자정)
    // 으로 맞춰야 이후 매핑이 두 서비스에서 동일하게 동작한다.
    return CalEventTime.allDay(DateTime(parsed.year, parsed.month, parsed.day));
  }
  return CalEventTime.at(parsed);
}

/// 그래프의 시각 문자열 파싱.
///
/// 그래프는 소수점 이하 **7자리**(`2026-08-29T10:00:00.0000000`)로 내려주는데
/// Dart 의 [DateTime.parse] 는 6자리까지만 받는다. 잘라내지 않으면 모든 일정이
/// 조용히 파싱 실패로 사라진다.
DateTime? _parseGraphInstant(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  var s = raw.trim();
  s = s.replaceFirstMapped(
    RegExp(r'\.(\d+)'),
    (m) => '.${m[1]!.padRight(6, '0').substring(0, 6)}',
  );
  final hasZone = s.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
  return DateTime.tryParse(hasZone ? s : '${s}Z');
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

const _graphWeekdays = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// 중립 반복 → 그래프 `patternedRecurrence`. 반복이 아니면 null.
///
/// 그래프는 RRULE 을 받지 않고 패턴 객체를 쓴다. 우리 규칙(daily / weekly+요일 /
/// monthly / yearly + 간격 + 종료일)은 전부 절대 패턴으로 표현된다.
Map<String, dynamic>? _toGraphRecurrence(CalEvent event) {
  final recurrence = event.recurrence;
  final rule = recurrence?.rule;
  final anchor = event.start?.value;
  if (rule == null || anchor == null) return null;
  final local = anchor.toLocal();

  final pattern = <String, dynamic>{'interval': rule.interval};
  switch (rule.freq) {
    case RecurrenceFreq.daily:
      pattern['type'] = 'daily';
    case RecurrenceFreq.weekly:
      pattern['type'] = 'weekly';
      final days = rule.byWeekday.isEmpty ? {local.weekday} : rule.byWeekday;
      pattern['daysOfWeek'] = [
        for (final wd in (days.toList()..sort())) _graphWeekdays[wd - 1],
      ];
      pattern['firstDayOfWeek'] = 'monday';
    case RecurrenceFreq.monthly:
      pattern['type'] = 'absoluteMonthly';
      pattern['dayOfMonth'] = local.day;
    case RecurrenceFreq.yearly:
      pattern['type'] = 'absoluteYearly';
      pattern['dayOfMonth'] = local.day;
      pattern['month'] = local.month;
  }

  final until = recurrence!.until;
  return {
    'pattern': pattern,
    'range': {
      'type': until == null ? 'noEnd' : 'endDate',
      'startDate': _ymd(local),
      if (until != null) 'endDate': _ymd(until.toLocal()),
      'recurrenceTimeZone': 'UTC',
    },
  };
}

/// 그래프 `patternedRecurrence` → 중립 반복.
///
/// 우리 모델로 표현할 수 없는 패턴(`relativeMonthly` 처럼 "매월 셋째 화요일")은
/// **근사하지 않는다** — `rule == null` 로 돌려 호출자가 단일 할 일로 폴백하게 한다.
/// 근사하면 앱이 계산한 발생일이 캘린더와 조용히 어긋난 채 굴러간다.
CalRecurrence? _fromGraphRecurrence(Object? raw) {
  if (raw is! Map) return null;
  final pattern = raw['pattern'];
  if (pattern is! Map) return const CalRecurrence();

  final interval = pattern['interval'];
  final n = interval is int ? interval : int.tryParse('$interval') ?? 1;

  RecurrenceFreq? freq;
  var byWeekday = <int>{};
  switch (pattern['type']) {
    case 'daily':
      freq = RecurrenceFreq.daily;
    case 'weekly':
      freq = RecurrenceFreq.weekly;
      final days = pattern['daysOfWeek'];
      if (days is List) {
        for (final d in days) {
          final i = _graphWeekdays.indexOf('$d'.toLowerCase());
          if (i < 0) return const CalRecurrence(); // 모르는 요일 — 포기
          byWeekday.add(i + 1);
        }
      }
    case 'absoluteMonthly':
      freq = RecurrenceFreq.monthly;
    case 'absoluteYearly':
      freq = RecurrenceFreq.yearly;
    default:
      return const CalRecurrence(); // relativeMonthly / relativeYearly 등
  }

  final range = raw['range'];
  DateTime? until;
  if (range is Map && range['type'] == 'endDate') {
    until = DateTime.tryParse('${range['endDate']}');
  }

  return CalRecurrence(
    rule: RecurrenceRule(
      freq: freq,
      interval: n < 1 ? 1 : n,
      byWeekday: freq == RecurrenceFreq.weekly ? byWeekday : const {},
    ),
    until: until,
  );
}

// ---------------------------------------------------------------------------
// 오류 분류
// ---------------------------------------------------------------------------

/// 재인증이 필요한 그래프 오류 코드.
const _graphAuthCodes = {
  'InvalidAuthenticationToken',
  'Authorization_RequestDenied',
  'ErrorAccessDenied',
  'AuthenticationError',
  'TokenNotFound',
};

/// 백오프 후 재시도할 오류 코드.
const _graphThrottleCodes = {
  'ActivityLimitReached',
  'TooManyRequests',
  'ApplicationThrottled',
  'QuotaLimitReached',
};

/// HTTP 상태 + 본문 → 게이트웨이 오류. **순수 함수** — 전 분기를 단위 테스트한다.
@visibleForTesting
CalendarGatewayException classifyGraphError(int status, String body) {
  final code = _graphErrorCode(body);
  final message = _graphErrorMessage(body) ?? body;

  if (status == 401 || (code != null && _graphAuthCodes.contains(code))) {
    return CalendarGatewayException(
      CalendarErrorKind.authRequired,
      status: status,
      message: message,
    );
  }
  if (status == 429 || (code != null && _graphThrottleCodes.contains(code))) {
    return CalendarGatewayException(
      CalendarErrorKind.rateLimited,
      status: status,
      message: message,
    );
  }
  // deltaLink 만료 — 그래프는 410 + `resyncRequired` 로 알린다.
  if (status == 410 ||
      code == 'resyncRequired' ||
      code == 'syncStateNotFound') {
    return CalendarGatewayException(
      CalendarErrorKind.syncTokenExpired,
      status: status,
      message: message,
    );
  }
  if (status >= 500) {
    return CalendarGatewayException(
      CalendarErrorKind.transient,
      status: status,
      message: message,
    );
  }
  return CalendarGatewayException(
    CalendarErrorKind.permanent,
    status: status,
    message: message,
  );
}

/// 네트워크·파싱 단계에서 난 오류의 분류 (HTTP 상태가 없는 경우).
@visibleForTesting
CalendarGatewayException classifyGraphTransportError(Object error) {
  if (error is CalendarGatewayException) return error;
  if (error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException) {
    return CalendarGatewayException(
      CalendarErrorKind.transient,
      message: error.toString(),
    );
  }
  debugPrint('[solo_todo] Microsoft Graph 오류: $error');
  return CalendarGatewayException(
    CalendarErrorKind.permanent,
    message: error.toString(),
  );
}

String? _graphErrorCode(String body) => _graphErrorField(body, 'code');

String? _graphErrorMessage(String body) => _graphErrorField(body, 'message');

String? _graphErrorField(String body, String field) {
  if (body.isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final error = decoded['error'];
    if (error is! Map) return null;
    final value = error[field];
    return value is String ? value : null;
  } catch (_) {
    return null;
  }
}
