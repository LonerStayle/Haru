import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_service.dart';
import 'package:solo_todo/src/features/calendar/google_calendar_gateway.dart';

/// date-repeat — buildEvent 의 반복 부착 + 구글 RRULE 변환 검증 (Phase H).
///
/// buildEvent 는 provider 중립 [CalRecurrence] 를 낸다. RRULE 문자열은 구글
/// 게이트웨이가 만들므로, "규칙이 실렸는가" 와 "RRULE 로 옳게 번역되는가" 를
/// 나눠서 확인한다.
void main() {
  Todo base({
    required String id,
    required DateTime dueAt,
    String? recurrenceRule,
    DateTime? recurrenceEndAt,
    bool isSeriesMaster = false,
    String? seriesId,
    bool isAllDay = false,
  }) => Todo(
    id: id,
    title: '매월 1일 정산',
    category: Category.work,
    dueAt: dueAt,
    doneAt: null,
    createdAt: dueAt,
    updatedAt: dueAt,
    isAllDay: isAllDay,
    seriesId: seriesId,
    recurrenceRule: recurrenceRule,
    recurrenceEndAt: recurrenceEndAt,
    isSeriesMaster: isSeriesMaster,
  );

  test('마스터(종일) → RRULE 부착', () {
    final master = base(
      id: 'm1',
      dueAt: DateTime.utc(2026, 6, 1),
      isAllDay: true,
      recurrenceRule: const RecurrenceRule(
        freq: RecurrenceFreq.monthly,
      ).encode(),
      isSeriesMaster: true,
      seriesId: 'm1',
    );
    final event = CalendarService.buildEvent(master);
    expect(
      event.recurrence?.rule,
      const RecurrenceRule(freq: RecurrenceFreq.monthly),
    );
    expect(event.recurrence?.until, isNull);
    expect(toGoogleEvent(event).recurrence, ['RRULE:FREQ=MONTHLY;INTERVAL=1']);
  });

  test('마스터 + 종료일 → RRULE 에 UNTIL(UTC) 포함', () {
    final master = base(
      id: 'm1',
      dueAt: DateTime.utc(2026, 6, 1, 9),
      recurrenceRule: RecurrenceRule(
        freq: RecurrenceFreq.weekly,
        byWeekday: const {DateTime.monday},
      ).encode(),
      recurrenceEndAt: DateTime.utc(2026, 12, 31),
      isSeriesMaster: true,
      seriesId: 'm1',
    );
    final event = CalendarService.buildEvent(master);
    expect(event.recurrence?.until, DateTime.utc(2026, 12, 31));
    expect(toGoogleEvent(event).recurrence, [
      'RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO;UNTIL=20261231T000000Z',
    ]);
  });

  test('인스턴스(규칙 없음) → RRULE 없음', () {
    final instance = base(
      id: 'm1#20260601',
      dueAt: DateTime.utc(2026, 6, 1, 9),
      seriesId: 'm1',
    );
    final event = CalendarService.buildEvent(instance);
    expect(event.recurrence, isNull);
    expect(toGoogleEvent(event).recurrence, isNull);
  });

  test('일반 Todo → RRULE 없음', () {
    final plain = base(id: 'p', dueAt: DateTime.utc(2026, 6, 1, 9));
    final event = CalendarService.buildEvent(plain);
    expect(event.recurrence, isNull);
    expect(toGoogleEvent(event).recurrence, isNull);
  });

  test('isSeriesMaster=true 이지만 규칙 문자열 없으면 부착 안 함(방어)', () {
    final weird = base(
      id: 'm1',
      dueAt: DateTime.utc(2026, 6, 1, 9),
      isSeriesMaster: true,
      seriesId: 'm1',
    );
    final event = CalendarService.buildEvent(weird);
    expect(event.recurrence, isNull);
  });
}
