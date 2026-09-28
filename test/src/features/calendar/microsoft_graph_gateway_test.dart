import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/features/calendar/calendar_auth.dart';
import 'package:solo_todo/src/features/calendar/calendar_event.dart';
import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/microsoft_graph_gateway.dart';

/// 요청을 기록하고 정해진 응답을 돌려주는 [CalendarAuth].
///
/// 실제 Microsoft 계정 없이 게이트웨이의 HTTP 경로(경로 조립 · 페이지네이션 ·
/// 오류 번역 · `$expand` 폴백)를 전부 덮기 위한 이음매다.
class _FakeAuth implements CalendarAuth {
  _FakeAuth(this.handler);

  final Future<http.Response> Function(http.Request request) handler;
  final requests = <http.Request>[];
  int authedClientCalls = 0;

  /// null 을 돌려주면 "동의 없음" — 게이트웨이가 재인증 필요로 알려야 한다.
  bool available = true;

  @override
  Future<http.Client?> authedClient() async {
    authedClientCalls++;
    if (!available) return null;
    return MockClient((request) {
      requests.add(request);
      return handler(request);
    });
  }

  @override
  Future<void> signOut() async {}
}

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('경로 조립', () {
    test('기본 캘린더 sentinel 은 /me/events 로 간다', () {
      expect(isDefaultMicrosoftCalendar(''), isTrue);
      expect(isDefaultMicrosoftCalendar('primary'), isTrue);
      expect(isDefaultMicrosoftCalendar('default'), isTrue);
      expect(isDefaultMicrosoftCalendar('AAMkAD...'), isFalse);

      expect(eventsPath(''), '/me/events');
      expect(eventsPath('primary'), '/me/events');
    });

    test('실제 캘린더 id 는 /me/calendars/{id}/events 로 간다', () {
      expect(eventsPath('cal 1'), '/me/calendars/cal%201/events');
    });
  });

  group('CalEvent → 그래프 JSON', () {
    test('종일 — isAllDay + 자정 경계 (종료는 exclusive 그대로)', () {
      final json = microsoftEventToJson(
        CalEvent(
          title: '휴가',
          description: '메모',
          start: CalEventTime.allDay(DateTime(2026, 8, 20)),
          end: CalEventTime.allDay(DateTime(2026, 8, 23)),
        ),
      );
      expect(json['subject'], '휴가');
      expect(json['isAllDay'], isTrue);
      expect(json['start'], {
        'dateTime': '2026-08-20T00:00:00',
        'timeZone': 'UTC',
      });
      expect(json['end'], {
        'dateTime': '2026-08-23T00:00:00',
        'timeZone': 'UTC',
      });
      expect((json['body']! as Map)['content'], '메모');
    });

    test('시간 이벤트 — timeZone 을 함께 보내므로 Z 표기는 뺀다', () {
      final json = microsoftEventToJson(
        CalEvent(
          title: '회의',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          end: CalEventTime.at(DateTime.utc(2026, 8, 20, 15)),
        ),
      );
      expect(json['isAllDay'], isFalse);
      expect((json['start']! as Map)['dateTime'], isNot(contains('Z')));
      expect(
        (json['start']! as Map)['dateTime'],
        startsWith('2026-08-20T14:00:00'),
      );
    });

    test('앱 서명은 확장 속성으로 실린다', () {
      final json = microsoftEventToJson(
        CalEvent(
          title: 'x',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          appProperties: const {'haruTodoId': 'todo-1', 'haruRev': 'rev-1'},
        ),
      );
      final props = json['singleValueExtendedProperties']! as List;
      expect(props, hasLength(2));
      expect(
        props.map((p) => (p as Map)['id']),
        everyElement(contains('Name haru')),
      );
      expect(
        props.firstWhere(
          (p) => ((p as Map)['id'] as String).endsWith('haruTodoId'),
        )['value'],
        'todo-1',
      );
    });

    test('반복 없음은 null 을 명시한다 — PATCH 에서 생략하면 옛 반복이 남는다', () {
      final json = microsoftEventToJson(
        CalEvent(
          title: 'x',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
        ),
      );
      expect(json.containsKey('recurrence'), isTrue);
      expect(json['recurrence'], isNull);
    });

    test('주간 반복 → weekly 패턴 + 종료일', () {
      final json = microsoftEventToJson(
        CalEvent(
          title: '주간 회의',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          recurrence: CalRecurrence(
            rule: const RecurrenceRule(
              freq: RecurrenceFreq.weekly,
              interval: 2,
              byWeekday: {1, 3},
            ),
            until: DateTime.utc(2026, 12, 31),
          ),
        ),
      );
      final pattern = (json['recurrence']! as Map)['pattern']! as Map;
      expect(pattern['type'], 'weekly');
      expect(pattern['interval'], 2);
      expect(pattern['daysOfWeek'], ['monday', 'wednesday']);
      final range = (json['recurrence']! as Map)['range']! as Map;
      expect(range['type'], 'endDate');
      expect(range['endDate'], '2026-12-31');
    });

    test('월간 반복은 시작일의 날짜를 절대 패턴으로 쓴다', () {
      final json = microsoftEventToJson(
        CalEvent(
          title: '정산',
          start: CalEventTime.allDay(DateTime(2026, 8, 7)),
          recurrence: const CalRecurrence(
            rule: RecurrenceRule(freq: RecurrenceFreq.monthly),
          ),
        ),
      );
      final pattern = (json['recurrence']! as Map)['pattern']! as Map;
      expect(pattern['type'], 'absoluteMonthly');
      expect(pattern['dayOfMonth'], 7);
      expect(((json['recurrence']! as Map)['range']! as Map)['type'], 'noEnd');
    });
  });

  group('그래프 JSON → CalEvent', () {
    test('시간 이벤트 — 소수점 7자리도 파싱된다', () {
      // 그래프 기본 응답이 7자리다. Dart 의 DateTime.parse 는 6자리까지만 받아
      // 자르지 않으면 모든 일정이 조용히 사라진다.
      final e = microsoftEventFromJson({
        'id': 'evt-1',
        'subject': '회의',
        'isAllDay': false,
        'isCancelled': false,
        'isOrganizer': true,
        'lastModifiedDateTime': '2026-08-19T08:00:00.1234567Z',
        'start': {'dateTime': '2026-08-20T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-08-20T15:00:00.0000000', 'timeZone': 'UTC'},
        'responseStatus': {'response': 'organizer'},
      });
      expect(e.id, 'evt-1');
      expect(e.title, '회의');
      expect(e.start!.dateTime!.toUtc(), DateTime.utc(2026, 8, 20, 14));
      expect(e.end!.dateTime!.toUtc(), DateTime.utc(2026, 8, 20, 15));
      expect(e.updated, isNotNull);
      expect(e.organizerIsSelf, isTrue);
      expect(e.selfResponseStatus, 'organizer');
      expect(e.cancelled, isFalse);
    });

    test('종일 이벤트는 날짜만 남는다 (구글의 start.date 와 같은 모양)', () {
      final e = microsoftEventFromJson({
        'id': 'evt-2',
        'subject': '휴가',
        'isAllDay': true,
        'start': {'dateTime': '2026-08-20T00:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-08-23T00:00:00.0000000', 'timeZone': 'UTC'},
      });
      expect(e.start!.isAllDay, isTrue);
      expect(e.start!.date, DateTime(2026, 8, 20));
      expect(e.end!.date, DateTime(2026, 8, 23));
    });

    test('@removed 는 tombstone — id 만 있어도 삭제로 읽힌다', () {
      final e = microsoftEventFromJson({
        'id': 'evt-3',
        '@removed': {'reason': 'deleted'},
      });
      expect(e.id, 'evt-3');
      expect(e.cancelled, isTrue);
    });

    test('isCancelled 도 취소로 읽는다', () {
      final e = microsoftEventFromJson({
        'id': 'evt-4',
        'isCancelled': true,
        'start': {'dateTime': '2026-08-20T14:00:00.0000000', 'timeZone': 'UTC'},
      });
      expect(e.cancelled, isTrue);
    });

    test('확장 속성이 실려 오면 앱 서명으로 복원된다', () {
      final e = microsoftEventFromJson({
        'id': 'evt-5',
        'subject': 'x',
        'start': {'dateTime': '2026-08-20T14:00:00.0000000', 'timeZone': 'UTC'},
        'singleValueExtendedProperties': [
          {
            'id':
                'String {6ed8da90-450b-101b-98da-00aa003f1305} '
                'Name haruTodoId',
            'value': 'todo-9',
          },
        ],
      });
      expect(e.appProperties['haruTodoId'], 'todo-9');
    });

    test('주최자 정보가 없으면 null 을 유지한다 — 단정하면 내 일정이 안 들어온다', () {
      final e = microsoftEventFromJson({
        'id': 'evt-6',
        'subject': 'x',
        'start': {'dateTime': '2026-08-20T14:00:00.0000000', 'timeZone': 'UTC'},
      });
      expect(e.organizerIsSelf, isNull);
    });

    test('표현 불가 반복(relativeMonthly)은 rule 없는 반복으로 남긴다', () {
      final e = microsoftEventFromJson({
        'id': 'evt-7',
        'subject': '매월 셋째 화요일',
        'start': {'dateTime': '2026-08-20T14:00:00.0000000', 'timeZone': 'UTC'},
        'recurrence': {
          'pattern': {
            'type': 'relativeMonthly',
            'interval': 1,
            'daysOfWeek': ['tuesday'],
            'index': 'third',
          },
          'range': {'type': 'noEnd'},
        },
      });
      expect(e.recurrence, isNotNull);
      expect(e.recurrence!.isSupported, isFalse);
    });

    test('주간 반복은 왕복한다', () {
      const rule = RecurrenceRule(
        freq: RecurrenceFreq.weekly,
        interval: 2,
        byWeekday: {1, 3},
      );
      final json = microsoftEventToJson(
        CalEvent(
          title: 'x',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          recurrence: CalRecurrence(
            rule: rule,
            until: DateTime.utc(2026, 12, 31),
          ),
        ),
      );
      final back = microsoftEventFromJson({
        'id': 'evt-8',
        'subject': 'x',
        'start': {'dateTime': '2026-08-20T14:00:00.0000000', 'timeZone': 'UTC'},
        'recurrence': json['recurrence'],
      });
      expect(back.recurrence!.rule, rule);
      expect(back.recurrence!.until, DateTime(2026, 12, 31));
    });
  });

  group('캘린더 목록', () {
    test('canEdit 이 owner/reader 로 번역된다', () async {
      final auth = _FakeAuth(
        (_) async => _json({
          'value': [
            {
              'id': 'c1',
              'name': '내 캘린더',
              'isDefaultCalendar': true,
              'canEdit': true,
            },
            {'id': 'c2', 'name': '공휴일', 'canEdit': false},
            {'name': 'id 없음'},
          ],
        }),
      );
      final list = await MicrosoftGraphGateway(auth).listCalendars();
      expect(list.map((c) => c.id), ['c1', 'c2']);
      expect(list.first.primary, isTrue);
      expect(list.first.canWrite, isTrue);
      expect(list.last.canWrite, isFalse);
    });
  });

  group('증분 수신 (delta)', () {
    test('nextLink 를 끝까지 따라가고 deltaLink 를 돌려준다', () async {
      var call = 0;
      final auth = _FakeAuth((request) async {
        call++;
        if (call == 1) {
          return _json({
            'value': [
              {
                'id': 'e1',
                'subject': 'A',
                'start': {
                  'dateTime': '2026-08-20T14:00:00.0000000',
                  'timeZone': 'UTC',
                },
              },
            ],
            '@odata.nextLink': 'https://graph.microsoft.com/v1.0/next-page',
          });
        }
        return _json({
          'value': [
            {'id': 'e2', '@removed': <String, Object>{}},
          ],
          '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-token',
        });
      });

      final page = await MicrosoftGraphGateway(auth).listChanges('c1');
      expect(page.events.map((e) => e.id), ['e1', 'e2']);
      expect(page.events.last.cancelled, isTrue);
      expect(
        page.nextSyncToken,
        'https://graph.microsoft.com/v1.0/delta-token',
      );
      // 첫 요청은 delta 경로 + 확장 속성 요청.
      expect(
        auth.requests.first.url.path,
        endsWith('/me/calendars/c1/events/delta'),
      );
      expect(auth.requests.first.url.query, contains('expand'));
    });

    test('저장된 deltaLink 가 있으면 그 URL 을 그대로 다시 부른다', () async {
      final auth = _FakeAuth(
        (_) async => _json({
          'value': <Object>[],
          '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/next-token',
        }),
      );
      await MicrosoftGraphGateway(auth).listChanges(
        'c1',
        syncToken: 'https://graph.microsoft.com/v1.0/saved-token',
      );
      expect(auth.requests.single.url.toString(), contains('saved-token'));
    });

    test('확장 속성 요청이 400 이면 확장 없이 한 번 더 시도한다', () async {
      var call = 0;
      final auth = _FakeAuth((request) async {
        call++;
        if (call == 1) {
          return _json({
            'error': {'code': 'RequestBroker--ParseUri', 'message': '지원 안 함'},
          }, status: 400);
        }
        return _json({
          'value': <Object>[],
          '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/token',
        });
      });

      final page = await MicrosoftGraphGateway(auth).listChanges('c1');
      expect(page.nextSyncToken, isNotNull);
      expect(auth.requests, hasLength(2));
      expect(auth.requests.first.url.query, contains('expand'));
      expect(auth.requests.last.url.query, isNot(contains('expand')));
    });

    test('토큰 만료(410 resyncRequired)는 전체 재동기화 신호로 올라온다', () async {
      final auth = _FakeAuth(
        (_) async => _json({
          'error': {'code': 'resyncRequired', 'message': '다시 동기화하세요'},
        }, status: 410),
      );
      await expectLater(
        MicrosoftGraphGateway(auth).listChanges('c1', syncToken: 'old'),
        throwsA(
          isA<CalendarGatewayException>().having(
            (e) => e.kind,
            'kind',
            CalendarErrorKind.syncTokenExpired,
          ),
        ),
      );
    });

    test('전체 조회는 timeMin 으로 거르되 tombstone 은 남긴다', () async {
      final auth = _FakeAuth(
        (_) async => _json({
          'value': [
            {
              'id': '옛날',
              'subject': '옛 일정',
              'start': {
                'dateTime': '2026-01-05T09:00:00.0000000',
                'timeZone': 'UTC',
              },
              'end': {
                'dateTime': '2026-01-05T10:00:00.0000000',
                'timeZone': 'UTC',
              },
            },
            {
              'id': '최근',
              'subject': '최근 일정',
              'start': {
                'dateTime': '2026-08-20T09:00:00.0000000',
                'timeZone': 'UTC',
              },
              'end': {
                'dateTime': '2026-08-20T10:00:00.0000000',
                'timeZone': 'UTC',
              },
            },
            {'id': '지워짐', '@removed': <String, Object>{}},
          ],
          '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/token',
        }),
      );

      final page = await MicrosoftGraphGateway(
        auth,
      ).listChanges('c1', timeMin: DateTime.utc(2026, 8, 1));
      expect(page.events.map((e) => e.id), ['최근', '지워짐']);
    });
  });

  group('쓰기 — 생성 / 수정 / 삭제', () {
    test('생성은 이벤트 컬렉션에 POST 하고 id 를 돌려준다', () async {
      final auth = _FakeAuth((_) async => _json({'id': 'new-1'}));
      final id = await MicrosoftGraphGateway(auth).insertEvent(
        'c1',
        CalEvent(
          title: 'x',
          start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
        ),
      );
      expect(id, 'new-1');
      expect(auth.requests.single.method, 'POST');
      expect(
        auth.requests.single.url.path,
        endsWith('/me/calendars/c1/events'),
      );
    });

    test('없는 이벤트 수정/삭제는 멱등 성공', () async {
      final auth = _FakeAuth(
        (_) async => _json({
          'error': {'code': 'ErrorItemNotFound', 'message': '없음'},
        }, status: 404),
      );
      final gw = MicrosoftGraphGateway(auth);
      await expectLater(
        gw.updateEvent(
          'c1',
          'gone',
          CalEvent(
            title: 'x',
            start: CalEventTime.at(DateTime.utc(2026, 8, 20, 14)),
          ),
        ),
        completes,
      );
      await expectLater(gw.deleteEvent('c1', 'gone'), completes);
    });

    test('동의가 없으면 재인증 필요로 알린다 — 조용한 no-op 금지', () async {
      final auth = _FakeAuth((_) async => _json(const <String, Object>{}))
        ..available = false;
      await expectLater(
        MicrosoftGraphGateway(auth).listCalendars(),
        throwsA(
          isA<CalendarGatewayException>().having(
            (e) => e.kind,
            'kind',
            CalendarErrorKind.authRequired,
          ),
        ),
      );
    });
  });

  group('classifyGraphError — 오류 매핑 (순수 함수)', () {
    String body(String code) => jsonEncode({
      'error': {'code': code, 'message': 'boom'},
    });

    test('401 → 재인증 필요', () {
      expect(
        classifyGraphError(401, body('InvalidAuthenticationToken')).kind,
        CalendarErrorKind.authRequired,
      );
    });

    test('권한 거부 코드는 상태와 무관하게 재인증 필요', () {
      expect(
        classifyGraphError(403, body('Authorization_RequestDenied')).kind,
        CalendarErrorKind.authRequired,
      );
    });

    test('429 / 스로틀 코드 → 재시도 가능', () {
      expect(
        classifyGraphError(429, body('TooManyRequests')).kind,
        CalendarErrorKind.rateLimited,
      );
      expect(
        classifyGraphError(503, body('ActivityLimitReached')).kind,
        CalendarErrorKind.rateLimited,
      );
      expect(classifyGraphError(429, '').isRetryable, isTrue);
    });

    test('410 / resyncRequired → 전체 재동기화', () {
      expect(
        classifyGraphError(410, '').kind,
        CalendarErrorKind.syncTokenExpired,
      );
      expect(
        classifyGraphError(400, body('resyncRequired')).kind,
        CalendarErrorKind.syncTokenExpired,
      );
    });

    test('5xx → 일시 장애', () {
      expect(classifyGraphError(500, '').kind, CalendarErrorKind.transient);
    });

    test('그 밖의 4xx → 영구 실패', () {
      final e = classifyGraphError(400, body('ErrorInvalidIdMalformed'));
      expect(e.kind, CalendarErrorKind.permanent);
      expect(e.isRetryable, isFalse);
      expect(e.status, 400);
    });

    test('본문이 JSON 이 아니어도 죽지 않는다', () {
      expect(
        classifyGraphError(500, '<html>gateway timeout</html>').kind,
        CalendarErrorKind.transient,
      );
    });

    test('이미 분류된 예외는 그대로 통과한다', () {
      final original = CalendarGatewayException.rateLimited();
      expect(
        identical(classifyGraphTransportError(original), original),
        isTrue,
      );
    });

    test('네트워크 오류는 일시 장애로 분류된다', () {
      expect(
        classifyGraphTransportError(http.ClientException('연결 끊김')).kind,
        CalendarErrorKind.transient,
      );
    });
  });
}
