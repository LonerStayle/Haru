import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_service.dart';
import 'package:solo_todo/src/features/calendar/event_to_todo.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 9);

  Todo make({
    String title = '제목',
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    String? recurrenceRule,
    DateTime? recurrenceEndAt,
    bool isSeriesMaster = false,
  }) => Todo(
    id: 'todo-1',
    title: title,
    category: Category.work,
    dueAt: dueAt,
    createdAt: t0,
    updatedAt: t0,
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
    seriesId: isSeriesMaster ? 'todo-1' : null,
    recurrenceRule: recurrenceRule,
    recurrenceEndAt: recurrenceEndAt,
    isSeriesMaster: isSeriesMaster,
  );

  /// 앱이 내보낸 이벤트를 그대로 되읽는다 (왕복).
  EventDatePatch? roundTrip(Todo t) {
    // ignore: invalid_use_of_visible_for_testing_member
    return eventToTodoPatch(CalendarService.buildEvent(t));
  }

  group('왕복 — 앱이 만든 이벤트는 모드가 보존된다', () {
    test('하루종일', () {
      final t = make(dueAt: DateTime(2026, 8, 20), isAllDay: true);
      final p = roundTrip(t)!;
      expect(p.dateMode, TodoDateMode.allDay);
      expect(p.isAllDay, isTrue);
      expect(p.endAt, isNull);
      expect(p.dueAt!.toLocal().day, 20);
    });

    test('시작시간 — 1시간 블록으로 나가도 range 로 변질되지 않는다', () {
      final t = make(dueAt: DateTime.utc(2026, 8, 20, 14));
      final p = roundTrip(t)!;
      expect(p.dateMode, TodoDateMode.startTime);
      expect(p.timeAnchor, 'start');
      expect(p.endAt, isNull);
      expect(p.dueAt!.toUtc(), DateTime.utc(2026, 8, 20, 14));
    });

    test('마감시간 — anchor 가 end 로 복원된다', () {
      final t = make(dueAt: DateTime.utc(2026, 8, 20, 18), timeAnchor: 'end');
      final p = roundTrip(t)!;
      expect(p.dateMode, TodoDateMode.endTime);
      expect(p.timeAnchor, 'end');
      expect(p.endAt, isNull);
      expect(p.dueAt!.toUtc(), DateTime.utc(2026, 8, 20, 18));
    });

    test('기간 + 시간', () {
      final t = make(
        dueAt: DateTime.utc(2026, 8, 20, 9),
        endAt: DateTime.utc(2026, 8, 20, 18),
      );
      final p = roundTrip(t)!;
      expect(p.dateMode, TodoDateMode.range);
      expect(p.isAllDay, isFalse);
      expect(p.dueAt!.toUtc(), DateTime.utc(2026, 8, 20, 9));
      expect(p.endAt!.toUtc(), DateTime.utc(2026, 8, 20, 18));
    });

    test('기간 + 하루종일 — exclusive 종료가 되돌려진다', () {
      final t = make(
        dueAt: DateTime(2026, 8, 20),
        endAt: DateTime(2026, 8, 23),
        isAllDay: true,
      );
      final p = roundTrip(t)!;
      expect(p.dateMode, TodoDateMode.range);
      expect(p.isAllDay, isTrue);
      expect(p.dueAt!.toLocal().day, 20);
      expect(p.endAt!.toLocal().day, 23); // +1일 exclusive 를 되돌림
    });

    test('제목도 함께 돌아온다', () {
      final p = roundTrip(make(title: '보고서 초안', dueAt: DateTime(2026, 8, 20)))!;
      expect(p.title, '보고서 초안');
    });

    test('캘린더에서 시간만 옮겨도 모드는 유지된다', () {
      // 앱이 startTime 으로 내보낸 이벤트를 사람이 캘린더에서 2시간 뒤로 끌었다.
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(
        make(dueAt: DateTime.utc(2026, 8, 20, 14)),
      );
      e.start = gcal.EventDateTime(
        dateTime: DateTime.utc(2026, 8, 20, 16),
        timeZone: 'UTC',
      );
      e.end = gcal.EventDateTime(
        dateTime: DateTime.utc(2026, 8, 20, 17),
        timeZone: 'UTC',
      );
      final p = eventToTodoPatch(e)!;
      expect(p.dateMode, TodoDateMode.startTime);
      expect(p.dueAt!.toUtc(), DateTime.utc(2026, 8, 20, 16));
      expect(p.endAt, isNull);
    });
  });

  group('서명 없는 이벤트 — 사람이 캘린더에서 만든 것', () {
    gcal.Event allDay(DateTime start, DateTime endExclusive) => gcal.Event(
      summary: '회의',
      start: gcal.EventDateTime(date: start),
      end: gcal.EventDateTime(date: endExclusive),
    );

    test('종일 하루 → allDay', () {
      final p = eventToTodoPatch(
        allDay(DateTime(2026, 8, 20), DateTime(2026, 8, 21)),
      )!;
      expect(p.dateMode, TodoDateMode.allDay);
      expect(p.isAllDay, isTrue);
      expect(p.endAt, isNull);
    });

    test('종일 여러 날 → range (end.date − 1일)', () {
      final p = eventToTodoPatch(
        allDay(DateTime(2026, 8, 20), DateTime(2026, 8, 23)),
      )!;
      expect(p.dateMode, TodoDateMode.range);
      expect(p.isAllDay, isTrue);
      expect(p.endAt!.day, 22); // 8/23 exclusive → 8/22 까지
    });

    test('시간 이벤트 → range', () {
      final p = eventToTodoPatch(
        gcal.Event(
          summary: '스탠드업',
          start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 9)),
          end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 9, 30)),
        ),
      )!;
      expect(p.dateMode, TodoDateMode.range);
      expect(p.isAllDay, isFalse);
      expect(p.dueAt!.toUtc(), DateTime.utc(2026, 8, 20, 9));
      expect(p.endAt!.toUtc(), DateTime.utc(2026, 8, 20, 9, 30));
    });

    test('제목이 없으면 빈 문자열이 아니라 안내 제목을 준다', () {
      final p = eventToTodoPatch(
        gcal.Event(
          start: gcal.EventDateTime(date: DateTime(2026, 8, 20)),
          end: gcal.EventDateTime(date: DateTime(2026, 8, 21)),
        ),
      )!;
      expect(p.title.trim(), isNotEmpty);
    });
  });

  group('매핑 불가', () {
    test('시작 시각이 없으면 null — 할 일로 만들 수 없다', () {
      expect(eventToTodoPatch(gcal.Event(summary: '무기한')), isNull);
    });
  });

  group('반복 이벤트', () {
    test('앱이 만든 반복 마스터는 규칙까지 왕복한다', () {
      const rule = RecurrenceRule(
        freq: RecurrenceFreq.weekly,
        interval: 2,
        byWeekday: {1, 3},
      );
      final t = make(
        dueAt: DateTime.utc(2026, 8, 20, 10),
        recurrenceRule: rule.encode(),
        recurrenceEndAt: DateTime.utc(2026, 12, 31),
        isSeriesMaster: true,
      );
      final p = roundTrip(t)!;
      expect(p.recurrence, rule);
      expect(p.recurrenceEndAt, DateTime.utc(2026, 12, 31));
    });

    test('미지원 RRULE 은 반복 없이 단일 할 일로 폴백', () {
      final e = gcal.Event(
        summary: '매월 첫 월요일',
        start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 10)),
        end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 11)),
        recurrence: ['RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1'],
      );
      final p = eventToTodoPatch(e)!;
      expect(p.recurrence, isNull);
      expect(p.unsupportedRecurrence, isTrue);
    });

    test('반복이 없으면 unsupportedRecurrence 는 false', () {
      final p = eventToTodoPatch(
        gcal.Event(
          summary: '단발',
          start: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 10)),
          end: gcal.EventDateTime(dateTime: DateTime.utc(2026, 8, 20, 11)),
        ),
      )!;
      expect(p.unsupportedRecurrence, isFalse);
    });
  });

  group('서명 읽기', () {
    test('haruTodoId / haruRev 를 그대로 노출한다', () {
      // ignore: invalid_use_of_visible_for_testing_member
      final e = CalendarService.buildEvent(make(dueAt: DateTime(2026, 8, 20)));
      final sig = readHaruSignature(e);
      expect(sig.todoId, 'todo-1');
      expect(sig.rev, t0.toUtc().toIso8601String());
    });

    test('서명 없는 이벤트는 빈 서명', () {
      final sig = readHaruSignature(gcal.Event(summary: 'x'));
      expect(sig.todoId, isNull);
      expect(sig.rev, isNull);
    });
  });
}
