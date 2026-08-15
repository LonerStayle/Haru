import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/features/calendar/calendar_gateway.dart';
import 'package:solo_todo/src/features/calendar/google_calendar_gateway.dart';

import 'fake_calendar_gateway.dart';

void main() {
  gcal.Event timed(String summary, DateTime start) => gcal.Event(
    summary: summary,
    start: gcal.EventDateTime(dateTime: start.toUtc(), timeZone: 'UTC'),
    end: gcal.EventDateTime(
      dateTime: start.toUtc().add(const Duration(hours: 1)),
      timeZone: 'UTC',
    ),
  );

  group('FakeCalendarGateway — CRUD 왕복', () {
    test('insert → listChanges → update → delete 가 왕복한다', () async {
      final gw = FakeCalendarGateway();

      // insert
      final id = await gw.insertEvent(
        'primary',
        timed('회의', DateTime.utc(2026, 8, 20, 10)),
      );
      expect(id, isNotNull);

      // list — 방금 넣은 이벤트가 보인다
      final first = await gw.listChanges('primary');
      expect(first.events.map((e) => e.id), [id]);
      expect(first.events.single.summary, '회의');
      expect(first.nextSyncToken, isNotNull);

      // update — 내용이 반영된다
      await gw.updateEvent(
        'primary',
        id!,
        timed('회의(장소 변경)', DateTime.utc(2026, 8, 20, 11)),
      );
      final afterUpdate = await gw.listChanges('primary');
      expect(afterUpdate.events.single.summary, '회의(장소 변경)');
      expect(
        afterUpdate.events.single.start!.dateTime!.toUtc(),
        DateTime.utc(2026, 8, 20, 11),
      );

      // delete — 살아있는 목록에서 사라지고 tombstone 만 남는다
      await gw.deleteEvent('primary', id);
      expect(gw.liveEvents('primary'), isEmpty);
      final afterDelete = await gw.listChanges('primary');
      expect(afterDelete.events.single.id, id);
      expect(afterDelete.events.single.status, 'cancelled');
    });

    test('insert 는 이벤트가 id 를 이미 갖고 있으면 그 id 를 보존한다', () async {
      final gw = FakeCalendarGateway();
      final e = timed('고정 id', DateTime.utc(2026, 8, 20, 10))..id = 'fixed-1';
      expect(await gw.insertEvent('primary', e), 'fixed-1');
      expect(gw.eventById('primary', 'fixed-1'), isNotNull);
    });

    test('저장은 복사본이다 — 호출자가 나중에 이벤트를 바꿔도 저장분은 안 변한다', () async {
      final gw = FakeCalendarGateway();
      final e = timed('원본', DateTime.utc(2026, 8, 20, 10));
      final id = await gw.insertEvent('primary', e);
      e.summary = '호출자가 나중에 바꿈';
      expect(gw.eventById('primary', id!)!.summary, '원본');
    });

    test('캘린더별로 저장이 분리된다', () async {
      final gw = FakeCalendarGateway(
        calendars: const [
          CalendarInfo(
            id: 'work',
            summary: '회사',
            primary: true,
            accessRole: 'owner',
          ),
          CalendarInfo(id: 'holiday', summary: '공휴일', accessRole: 'reader'),
        ],
      );
      await gw.insertEvent('work', timed('업무', DateTime.utc(2026, 8, 20, 10)));
      expect(gw.liveEvents('work'), hasLength(1));
      expect(gw.liveEvents('holiday'), isEmpty);
    });
  });

  group('FakeCalendarGateway — 404/410 멱등', () {
    test('없는 이벤트 delete 는 성공한다 (이미 없음 = 목표 달성)', () async {
      final gw = FakeCalendarGateway();
      await expectLater(gw.deleteEvent('primary', 'no-such'), completes);
    });

    test('없는 이벤트 update 는 성공하되 이벤트를 되살리지 않는다', () async {
      final gw = FakeCalendarGateway();
      await expectLater(
        gw.updateEvent(
          'primary',
          'no-such',
          timed('부활 금지', DateTime.utc(2026, 8, 20, 10)),
        ),
        completes,
      );
      expect(gw.liveEvents('primary'), isEmpty);
      expect(gw.eventById('primary', 'no-such'), isNull);
    });

    test('이미 삭제된(cancelled) 이벤트의 update/delete 도 멱등이다', () async {
      final gw = FakeCalendarGateway();
      final id = (await gw.insertEvent(
        'primary',
        timed('한번', DateTime.utc(2026, 8, 20, 10)),
      ))!;
      await gw.deleteEvent('primary', id);

      await expectLater(gw.deleteEvent('primary', id), completes);
      await expectLater(
        gw.updateEvent('primary', id, timed('부활?', DateTime.utc(2026, 8, 20))),
        completes,
      );
      expect(gw.eventById('primary', id)!.status, 'cancelled');
      expect(gw.liveEvents('primary'), isEmpty);
    });
  });

  group('FakeCalendarGateway — syncToken 증분', () {
    test('토큰 이후 변경분만 돌려준다', () async {
      final gw = FakeCalendarGateway();
      await gw.insertEvent('primary', timed('A', DateTime.utc(2026, 8, 20, 9)));
      final page1 = await gw.listChanges('primary');
      expect(page1.events, hasLength(1));

      // 아무 변경 없음 → 빈 페이지
      final page2 = await gw.listChanges(
        'primary',
        syncToken: page1.nextSyncToken,
      );
      expect(page2.events, isEmpty);
      expect(page2.nextSyncToken, isNotNull);

      // B 추가 → B 만
      final idB = await gw.insertEvent(
        'primary',
        timed('B', DateTime.utc(2026, 8, 21, 9)),
      );
      final page3 = await gw.listChanges(
        'primary',
        syncToken: page2.nextSyncToken,
      );
      expect(page3.events.map((e) => e.id), [idB]);
    });

    test('증분 페이지는 삭제를 cancelled 로 알려준다', () async {
      final gw = FakeCalendarGateway();
      final id = (await gw.insertEvent(
        'primary',
        timed('A', DateTime.utc(2026, 8, 20, 9)),
      ))!;
      final page1 = await gw.listChanges('primary');
      await gw.deleteEvent('primary', id);

      final page2 = await gw.listChanges(
        'primary',
        syncToken: page1.nextSyncToken,
      );
      expect(page2.events.single.id, id);
      expect(page2.events.single.status, 'cancelled');
    });

    test('만료된 토큰은 syncTokenExpired 로 알려준다 (전체 재동기화 신호)', () async {
      final gw = FakeCalendarGateway();
      await gw.insertEvent('primary', timed('A', DateTime.utc(2026, 8, 20, 9)));
      final page1 = await gw.listChanges('primary');
      gw.expireSyncTokens();

      expect(
        () => gw.listChanges('primary', syncToken: page1.nextSyncToken),
        throwsA(
          isA<CalendarGatewayException>().having(
            (e) => e.kind,
            'kind',
            CalendarErrorKind.syncTokenExpired,
          ),
        ),
      );

      // 폴백 — 토큰 없이 전체 조회는 여전히 동작한다
      final full = await gw.listChanges('primary');
      expect(full.events, hasLength(1));
      expect(full.nextSyncToken, isNotNull);
    });

    test('알 수 없는 토큰도 syncTokenExpired', () async {
      final gw = FakeCalendarGateway();
      expect(
        () => gw.listChanges('primary', syncToken: '아무거나'),
        throwsA(isA<CalendarGatewayException>()),
      );
    });

    test('토큰 없는 전체 조회는 timeMin 으로 거른다', () async {
      final gw = FakeCalendarGateway();
      await gw.insertEvent('primary', timed('옛날', DateTime.utc(2026, 1, 5, 9)));
      await gw.insertEvent(
        'primary',
        timed('최근', DateTime.utc(2026, 8, 20, 9)),
      );

      final page = await gw.listChanges(
        'primary',
        timeMin: DateTime.utc(2026, 8, 1),
      );
      expect(page.events.map((e) => e.summary), ['최근']);
    });
  });

  group('FakeCalendarGateway — 오류 주입', () {
    test('failNext 는 지정 연산만 1회 실패시킨다', () async {
      final gw = FakeCalendarGateway();
      gw.failNext(
        CalendarGatewayException.rateLimited(),
        op: CalendarOp.insertEvent,
      );

      // 다른 연산은 영향 없음
      await expectLater(gw.listChanges('primary'), completes);

      await expectLater(
        gw.insertEvent('primary', timed('X', DateTime.utc(2026, 8, 20, 9))),
        throwsA(
          isA<CalendarGatewayException>()
              .having((e) => e.kind, 'kind', CalendarErrorKind.rateLimited)
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );

      // 소진 후에는 정상
      expect(
        await gw.insertEvent(
          'primary',
          timed('X', DateTime.utc(2026, 8, 20, 9)),
        ),
        isNotNull,
      );
    });

    test('failNext(times:) 로 N회 연속 실패 후 성공 — 백오프 테스트용', () async {
      final gw = FakeCalendarGateway();
      gw.failNext(
        CalendarGatewayException.transient(),
        op: CalendarOp.insertEvent,
        times: 2,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          gw.insertEvent('primary', timed('X', DateTime.utc(2026, 8, 20, 9))),
          throwsA(isA<CalendarGatewayException>()),
        );
      }
      expect(
        await gw.insertEvent(
          'primary',
          timed('X', DateTime.utc(2026, 8, 20, 9)),
        ),
        isNotNull,
      );
    });

    test('failAlways 는 clearFailures 전까지 계속 실패한다', () async {
      final gw = FakeCalendarGateway();
      gw.failAlways(CalendarGatewayException.authRequired());
      for (var i = 0; i < 3; i++) {
        await expectLater(
          gw.listCalendars(),
          throwsA(
            isA<CalendarGatewayException>()
                .having((e) => e.kind, 'kind', CalendarErrorKind.authRequired)
                .having((e) => e.isRetryable, 'isRetryable', isFalse),
          ),
        );
      }
      gw.clearFailures();
      await expectLater(gw.listCalendars(), completes);
    });

    test('callCount 로 호출 횟수를 확인할 수 있다 (echo 차단 검증용)', () async {
      final gw = FakeCalendarGateway();
      expect(gw.callCount(CalendarOp.insertEvent), 0);
      await gw.insertEvent('primary', timed('X', DateTime.utc(2026, 8, 20, 9)));
      await gw.insertEvent('primary', timed('Y', DateTime.utc(2026, 8, 21, 9)));
      expect(gw.callCount(CalendarOp.insertEvent), 2);
      expect(gw.callCount(CalendarOp.updateEvent), 0);
    });
  });

  group('FakeCalendarGateway — 원격 상태 구성 (arrange)', () {
    test('seedEvent 는 앱 호출로 세지 않고 원격 이벤트를 심는다', () async {
      final gw = FakeCalendarGateway();
      gw.seedEvent(
        'primary',
        gcal.Event(
          id: 'remote-1',
          summary: '구글에서 만든 일정',
          updated: DateTime.utc(2026, 8, 19, 8),
          start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 9)),
          end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 10)),
        ),
      );
      expect(gw.callCount(CalendarOp.insertEvent), 0);

      final page = await gw.listChanges('primary');
      expect(page.events.single.id, 'remote-1');
      expect(page.events.single.updated, DateTime.utc(2026, 8, 19, 8));
    });

    test('cancelRemotely 는 구글 쪽 삭제를 흉내낸다', () async {
      final gw = FakeCalendarGateway();
      gw.seedEvent('primary', gcal.Event(id: 'remote-1', summary: '일정'));
      final page1 = await gw.listChanges('primary');

      gw.cancelRemotely('primary', 'remote-1');
      final page2 = await gw.listChanges(
        'primary',
        syncToken: page1.nextSyncToken,
      );
      expect(page2.events.single.status, 'cancelled');
      expect(gw.liveEvents('primary'), isEmpty);
    });

    test('listCalendars 는 주입한 캘린더 목록을 그대로 준다', () async {
      final gw = FakeCalendarGateway(
        calendars: const [
          CalendarInfo(
            id: 'me',
            summary: '내 캘린더',
            primary: true,
            accessRole: 'owner',
          ),
          CalendarInfo(id: 'kr-holiday', summary: '대한민국 공휴일'),
        ],
      );
      final list = await gw.listCalendars();
      expect(list.map((c) => c.id), ['me', 'kr-holiday']);
      expect(list.first.canWrite, isTrue);
      expect(list.last.canWrite, isFalse); // 읽기 전용에 쓰기 금지
    });
  });

  group('CalendarInfo', () {
    test('canWrite 는 owner / writer 만 참', () {
      const roles = {
        'owner': true,
        'writer': true,
        'reader': false,
        'freeBusyReader': false,
        'none': false,
      };
      roles.forEach((role, expected) {
        expect(
          CalendarInfo(id: 'x', summary: 'x', accessRole: role).canWrite,
          expected,
          reason: role,
        );
      });
    });

    test('값 동등성 — 설정 저장/복원 비교에 쓴다', () {
      expect(
        const CalendarInfo(id: 'a', summary: 'A', accessRole: 'owner'),
        const CalendarInfo(id: 'a', summary: 'A', accessRole: 'owner'),
      );
      expect(
        const CalendarInfo(id: 'a', summary: 'A'),
        isNot(const CalendarInfo(id: 'b', summary: 'A')),
      );
    });
  });

  group('classifyCalendarError — 오류 매핑 (순수 함수)', () {
    // 실제 Calendar API 오류 본문 형태 그대로 만든다.
    gcal.DetailedApiRequestError apiError(int status, {String? reason}) =>
        gcal.DetailedApiRequestError(
          status,
          'boom',
          jsonResponse: {
            'error': {
              'code': status,
              'message': 'boom',
              if (reason != null)
                'errors': [
                  {'domain': 'global', 'reason': reason, 'message': 'boom'},
                ],
            },
          },
        );

    test('401 → 재인증 필요', () {
      final e = classifyCalendarError(apiError(401));
      expect(e.kind, CalendarErrorKind.authRequired);
      expect(e.isRetryable, isFalse);
    });

    test('403 insufficientPermissions → 재인증 필요 (scope 부족)', () {
      expect(
        classifyCalendarError(
          apiError(403, reason: 'insufficientPermissions'),
        ).kind,
        CalendarErrorKind.authRequired,
      );
    });

    test('403 rateLimitExceeded / 429 → 재시도 가능', () {
      expect(
        classifyCalendarError(apiError(403, reason: 'rateLimitExceeded')).kind,
        CalendarErrorKind.rateLimited,
      );
      expect(
        classifyCalendarError(
          apiError(403, reason: 'userRateLimitExceeded'),
        ).kind,
        CalendarErrorKind.rateLimited,
      );
      expect(
        classifyCalendarError(apiError(429)).kind,
        CalendarErrorKind.rateLimited,
      );
      expect(classifyCalendarError(apiError(429)).isRetryable, isTrue);
    });

    test('403 forbidden (권한 없는 캘린더) → 영구 실패', () {
      expect(
        classifyCalendarError(apiError(403, reason: 'forbidden')).kind,
        CalendarErrorKind.permanent,
      );
    });

    test('410 → syncToken 만료 (전체 재동기화 신호)', () {
      expect(
        classifyCalendarError(apiError(410)).kind,
        CalendarErrorKind.syncTokenExpired,
      );
    });

    test('5xx → 재시도 가능', () {
      expect(
        classifyCalendarError(apiError(500)).kind,
        CalendarErrorKind.transient,
      );
      expect(classifyCalendarError(apiError(503)).isRetryable, isTrue);
    });

    test('400 → 영구 실패', () {
      expect(
        classifyCalendarError(apiError(400)).kind,
        CalendarErrorKind.permanent,
      );
    });

    test('invalid_grant 문자열 → 재인증 필요', () {
      expect(
        classifyCalendarError(Exception('refresh failed: invalid_grant')).kind,
        CalendarErrorKind.authRequired,
      );
    });

    test('이미 분류된 예외는 그대로 통과한다 (이중 래핑 금지)', () {
      final original = CalendarGatewayException.syncTokenExpired();
      expect(identical(classifyCalendarError(original), original), isTrue);
    });
  });
}
