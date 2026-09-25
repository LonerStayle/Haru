import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_providers.dart';

/// 구글 오버레이 — 이미 할 일로 보이는 일정은 두 번 그리지 않는다 (2026-09-25 제보).
void main() {
  GoogleEventEntry g(String id, DateTime day, {String? recurring}) =>
      GoogleEventEntry(
        id: id,
        recurringEventId: recurring,
        title: 'g-$id',
        start: day,
        end: day,
        isAllDay: true,
      );

  Todo todo(
    String id,
    DateTime due, {
    String? eventId,
    String? seriesId,
    bool master = false,
  }) => Todo(
    id: id,
    title: id,
    category: Category.daily,
    dueAt: due,
    isAllDay: true,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    calendarEventId: eventId,
    seriesId: seriesId,
    isSeriesMaster: master,
  );

  List<String> ids(List<GoogleEventEntry> events, List<CalendarEntry> local) =>
      [for (final e in hideLinkedGoogleEvents(events, local)) e.id];

  final d = DateTime(2026, 9, 25);

  test('할 일에 연결된 일정(같은 id)은 숨기고, 연결 없는 일정은 그대로', () {
    final local = [TodoEntry(todo('t', d, eventId: 'ev1'))];
    expect(ids([g('ev1', d), g('other', d)], local), ['other']);
  });

  test('단발 할 일이 반복 원본에 연결됨(생일을 한 번 가져옴) → 그 날짜 회차만 숨김', () {
    final local = [
      TodoEntry(todo('birthday', DateTime(2026, 3, 15), eventId: 'bday')),
    ];
    final events = [
      g('bday_20260315', DateTime(2026, 3, 15), recurring: 'bday'),
      g('bday_20270315', DateTime(2027, 3, 15), recurring: 'bday'),
    ];
    expect(ids(events, local), ['bday_20270315']);
  });

  test('앱 반복(회차·고스트)에 연결된 원본이면 모든 회차를 숨김', () {
    final master = todo(
      'm',
      DateTime(2026, 9, 1),
      eventId: 'weekly',
      seriesId: 'm',
      master: true,
    );
    final local = <CalendarEntry>[
      RecurringGhostEntry(master: master, date: DateTime(2026, 9, 29)),
    ];
    final events = [
      g('weekly_20260922', DateTime(2026, 9, 22), recurring: 'weekly'),
      g('weekly_20260929', DateTime(2026, 9, 29), recurring: 'weekly'),
      g('solo', d),
    ];
    expect(ids(events, local), ['solo']);
  });

  test('연결된 할 일이 없으면 그대로 돌려준다', () {
    final events = [g('a', d), g('b', d)];
    expect(hideLinkedGoogleEvents(events, [TodoEntry(todo('x', d))]), events);
  });
}
