import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/date_format.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  Todo make({
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
  }) => Todo(
    id: 'x',
    title: 't',
    category: Category.work,
    dueAt: dueAt,
    doneAt: null,
    createdAt: DateTime.utc(2026, 5, 27, 9),
    updatedAt: DateTime.utc(2026, 5, 27, 9),
    calendarEventId: null,
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
  );

  group('TodoDateMode 도출', () {
    test('dueAt 없음 → none', () {
      expect(make().dateMode, TodoDateMode.none);
    });
    test('isAllDay → allDay', () {
      expect(
        make(dueAt: DateTime(2026, 5, 27), isAllDay: true).dateMode,
        TodoDateMode.allDay,
      );
    });
    test('시간 + start → startTime', () {
      expect(
        make(dueAt: DateTime(2026, 5, 27, 14, 30)).dateMode,
        TodoDateMode.startTime,
      );
    });
    test('시간 + end → endTime', () {
      expect(
        make(dueAt: DateTime(2026, 5, 27, 14, 30), timeAnchor: 'end').dateMode,
        TodoDateMode.endTime,
      );
    });
    test('endAt 있음 → range', () {
      expect(
        make(
          dueAt: DateTime(2026, 5, 27),
          endAt: DateTime(2026, 5, 30),
        ).dateMode,
        TodoDateMode.range,
      );
    });
  });

  group('TodoDateLabel.format — Task 1: 하루종일은 시간 미출력', () {
    test('none → null', () {
      expect(TodoDateLabel.format(make()), isNull);
    });

    test('하루종일 → "5/27" (00:00 / 오전 12:00 절대 미출력)', () {
      final label = TodoDateLabel.format(
        make(dueAt: DateTime(2026, 5, 27), isAllDay: true),
      );
      expect(label, '5/27');
      expect(label, isNot(contains(':')));
      expect(label, isNot(contains('00:00')));
      expect(label, isNot(contains('오전')));
    });

    test('시작시간 → "시작 5/27 14:30"', () {
      expect(
        TodoDateLabel.format(make(dueAt: DateTime(2026, 5, 27, 14, 30))),
        '시작 5/27 14:30',
      );
    });

    test('마감시간 → "마감 5/27 09:05"', () {
      expect(
        TodoDateLabel.format(
          make(dueAt: DateTime(2026, 5, 27, 9, 5), timeAnchor: 'end'),
        ),
        '마감 5/27 09:05',
      );
    });

    test('기간 + 하루종일 → "5/27 ~ 5/30" (시간 미출력)', () {
      final label = TodoDateLabel.format(
        make(
          dueAt: DateTime(2026, 5, 27),
          endAt: DateTime(2026, 5, 30),
          isAllDay: true,
        ),
      );
      expect(label, '5/27 ~ 5/30');
      expect(label, isNot(contains(':')));
    });

    test('기간 + 시간 → "5/27 09:00 ~ 5/30 18:30"', () {
      expect(
        TodoDateLabel.format(
          make(
            dueAt: DateTime(2026, 5, 27, 9, 0),
            endAt: DateTime(2026, 5, 30, 18, 30),
          ),
        ),
        '5/27 09:00 ~ 5/30 18:30',
      );
    });
  });

  group('KoDate — 캘린더 헤더 포맷 (v1.6)', () {
    test('monthTitle 은 연도를 함께 낸다 — 달 넘김으로 해가 바뀌는 걸 놓치지 않도록', () {
      expect(KoDate.monthTitle(DateTime(2026, 8, 15)), '2026년 8월');
      // 같은 달이면 일(day)과 무관하게 동일한 라벨.
      expect(KoDate.monthTitle(DateTime(2026, 8, 1)), '2026년 8월');
      expect(KoDate.monthTitle(DateTime(2027, 1, 31)), '2027년 1월');
    });

    test('dayWithWeekday 는 "8월 15일 (토)" — 괄호 한 글자 요일로 폭을 아낀다', () {
      // 2026-08-15 는 토요일.
      expect(KoDate.dayWithWeekday(DateTime(2026, 8, 15)), '8월 15일 (토)');
      // 2026-08-17 은 월요일.
      expect(KoDate.dayWithWeekday(DateTime(2026, 8, 17)), '8월 17일 (월)');
      // pretty 의 "…요일" 표기와 달리 접미사를 붙이지 않는다.
      expect(
        KoDate.dayWithWeekday(DateTime(2026, 8, 15)),
        isNot(contains('요일')),
      );
    });

    test('weekdayShort 는 DateTime.weekday 규약 (1=월 … 7=일)', () {
      expect(KoDate.weekdayShort(DateTime.monday), '월');
      expect(KoDate.weekdayShort(DateTime.saturday), '토');
      expect(KoDate.weekdayShort(DateTime.sunday), '일');
      // 실제 날짜의 weekday 로도 일치.
      expect(KoDate.weekdayShort(DateTime(2026, 8, 15).weekday), '토');
    });
  });
}
