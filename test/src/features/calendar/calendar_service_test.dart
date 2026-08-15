import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_service.dart';

void main() {
  test('GoogleAuthService 미설정 → calendarServiceProvider == null', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(calendarServiceProvider), isNull);
  });

  Todo make({
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    DateTime? doneAt,
    DateTime? updatedAt,
  }) => Todo(
    id: 'x',
    title: '제목',
    category: Category.work,
    dueAt: dueAt,
    doneAt: doneAt,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: updatedAt ?? DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
  );

  group('fast-tasks — buildEvent 매핑', () {
    test('하루종일 → all-day 이벤트 (start.date / end.date = 종료+1일)', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(dueAt: DateTime(2026, 5, 27), isAllDay: true),
      );
      expect(e.start!.date, DateTime(2026, 5, 27));
      expect(e.start!.dateTime, isNull);
      expect(e.end!.date, DateTime(2026, 5, 28)); // exclusive 다음날
    });

    test('단일 시작시간 → 1시간 timed 이벤트', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(dueAt: DateTime.utc(2026, 5, 27, 14, 0)),
      );
      expect(e.start!.dateTime, isNotNull);
      expect(e.start!.date, isNull);
      expect(
        e.end!.dateTime!.difference(e.start!.dateTime!),
        const Duration(hours: 1),
      );
    });

    test('단일 마감시간 → 1시간 timed 이벤트 (anchor 는 표시용)', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(dueAt: DateTime.utc(2026, 5, 27, 18, 0), timeAnchor: 'end'),
      );
      expect(e.start!.dateTime, isNotNull);
      expect(
        e.end!.dateTime!.difference(e.start!.dateTime!),
        const Duration(hours: 1),
      );
    });

    test('기간 + 하루종일 → all-day (end.date = 종료+1일)', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(
          dueAt: DateTime(2026, 5, 27),
          endAt: DateTime(2026, 5, 30),
          isAllDay: true,
        ),
      );
      expect(e.start!.date, DateTime(2026, 5, 27));
      expect(e.end!.date, DateTime(2026, 5, 31));
    });

    test('기간 + 시간 → start.dateTime=dueAt, end.dateTime=endAt', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(
          dueAt: DateTime.utc(2026, 5, 27, 9, 0),
          endAt: DateTime.utc(2026, 5, 27, 18, 30),
        ),
      );
      expect(e.start!.dateTime!.toUtc(), DateTime.utc(2026, 5, 27, 9, 0));
      expect(e.end!.dateTime!.toUtc(), DateTime.utc(2026, 5, 27, 18, 30));
    });
  });

  group('google-calendar-sync — 완료 표시(colorId)', () {
    test('완료된 할 일 → 회색(colorId=8)', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(
          dueAt: DateTime.utc(2026, 5, 27, 14),
          doneAt: DateTime.utc(2026, 5, 27, 15),
        ),
      );
      expect(e.colorId, '8');
    });

    test('미완료 → colorId 없음 (캘린더 기본색 복구)', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(dueAt: DateTime.utc(2026, 5, 27, 14)),
      );
      expect(e.colorId, isNull);
    });

    test('완료해도 제목은 그대로 — 역방향 파싱 오염 방지', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(
          dueAt: DateTime.utc(2026, 5, 27, 14),
          doneAt: DateTime.utc(2026, 5, 27, 15),
        ),
      );
      expect(e.summary, '제목');
    });
  });

  group('google-calendar-sync — 앱 서명(extendedProperties)', () {
    Map<String, String> signatureOf(Todo t) {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(t);
      return e.extendedProperties!.private!;
    }

    test('haruTodoId — 링크 복구용 할 일 id', () {
      expect(
        signatureOf(make(dueAt: DateTime.utc(2026, 5, 27, 14)))['haruTodoId'],
        'x',
      );
    });

    test('haruRev — updatedAt 의 UTC ISO8601 (echo 차단 비교 기준)', () {
      final updated = DateTime.utc(2026, 5, 27, 9, 30, 15);
      expect(
        signatureOf(
          make(dueAt: DateTime.utc(2026, 5, 27, 14), updatedAt: updated),
        )['haruRev'],
        updated.toUtc().toIso8601String(),
      );
    });

    test('haruRev — local 시각도 UTC 로 정규화된다', () {
      final local = DateTime(2026, 5, 27, 9, 30);
      final rev = signatureOf(
        make(dueAt: DateTime.utc(2026, 5, 27, 14), updatedAt: local),
      )['haruRev'];
      expect(rev, local.toUtc().toIso8601String());
      expect(rev, endsWith('Z'));
    });

    test('haruDateMode — 날짜 모드 5종이 그대로 실린다', () {
      expect(
        signatureOf(
          make(dueAt: DateTime(2026, 5, 27), isAllDay: true),
        )['haruDateMode'],
        TodoDateMode.allDay.name,
      );
      expect(
        signatureOf(make(dueAt: DateTime.utc(2026, 5, 27, 14)))['haruDateMode'],
        TodoDateMode.startTime.name,
      );
      expect(
        signatureOf(
          make(dueAt: DateTime.utc(2026, 5, 27, 14), timeAnchor: 'end'),
        )['haruDateMode'],
        TodoDateMode.endTime.name,
      );
      expect(
        signatureOf(
          make(
            dueAt: DateTime.utc(2026, 5, 27, 9),
            endAt: DateTime.utc(2026, 5, 27, 18),
          ),
        )['haruDateMode'],
        TodoDateMode.range.name,
      );
    });

    test('haruAnchor — timeAnchor 가 그대로 실린다', () {
      expect(
        signatureOf(
          make(dueAt: DateTime.utc(2026, 5, 27, 14), timeAnchor: 'end'),
        )['haruAnchor'],
        'end',
      );
      expect(
        signatureOf(make(dueAt: DateTime.utc(2026, 5, 27, 14)))['haruAnchor'],
        'start',
      );
    });
  });
}
