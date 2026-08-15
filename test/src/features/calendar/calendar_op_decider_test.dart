import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_op_decider.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 9);
  const writeCalendar = 'work@group.calendar.google.com';

  Todo make({
    String id = 'todo-1',
    String title = '제목',
    Category? category,
    DateTime? dueAt,
    DateTime? endAt,
    DateTime? doneAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    String? calendarEventId,
    String? calendarId,
    String calendarOrigin = 'app',
    TodoType type = TodoType.task,
    int sortOrder = 0,
    String? parentId,
    String? description,
    String? seriesId,
    String? recurrenceRule,
    DateTime? recurrenceEndAt,
    bool isSeriesMaster = false,
  }) => Todo(
    id: id,
    title: title,
    category: category ?? Category.work,
    dueAt: dueAt,
    doneAt: doneAt,
    createdAt: t0,
    updatedAt: t0,
    calendarEventId: calendarEventId,
    calendarId: calendarId,
    calendarOrigin: calendarOrigin,
    parentId: parentId,
    type: type,
    sortOrder: sortOrder,
    description: description,
    endAt: endAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
    seriesId: seriesId,
    recurrenceRule: recurrenceRule,
    recurrenceEndAt: recurrenceEndAt,
    isSeriesMaster: isSeriesMaster,
  );

  CalendarOpDecision decide(
    Todo? prev,
    Todo next, {
    bool addToCalendar = true,
  }) => decideCalendarOp(
    prev: prev,
    next: next,
    addToCalendar: addToCalendar,
    writeCalendarId: writeCalendar,
  );

  /// 이미 캘린더에 등록된 할 일 (링크 보유).
  Todo linked({
    String title = '제목',
    Category? category,
    DateTime? dueAt,
    DateTime? endAt,
    DateTime? doneAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    TodoType type = TodoType.task,
    int sortOrder = 0,
    String? parentId,
    String? description,
    String? recurrenceRule,
    DateTime? recurrenceEndAt,
  }) => make(
    title: title,
    category: category,
    dueAt: dueAt ?? DateTime.utc(2026, 8, 20, 14),
    endAt: endAt,
    doneAt: doneAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
    type: type,
    sortOrder: sortOrder,
    parentId: parentId,
    description: description,
    recurrenceRule: recurrenceRule,
    recurrenceEndAt: recurrenceEndAt,
    calendarEventId: 'ev-1',
    calendarId: writeCalendar,
  );

  group('감시 필드 — 하나라도 바뀌면 update', () {
    test('title', () {
      final d = decide(linked(), linked(title: '바뀐 제목'));
      expect(d.kind, CalendarOpKind.update);
      expect(d.eventId, 'ev-1');
      expect(d.calendarId, writeCalendar);
    });

    test('dueAt', () {
      final d = decide(linked(), linked(dueAt: DateTime.utc(2026, 8, 21, 14)));
      expect(d.kind, CalendarOpKind.update);
    });

    test('endAt', () {
      final d = decide(linked(), linked(endAt: DateTime.utc(2026, 8, 20, 18)));
      expect(d.kind, CalendarOpKind.update);
    });

    test('isAllDay', () {
      final d = decide(linked(), linked(isAllDay: true));
      expect(d.kind, CalendarOpKind.update);
    });

    test('timeAnchor', () {
      final d = decide(linked(), linked(timeAnchor: 'end'));
      expect(d.kind, CalendarOpKind.update);
    });

    test('doneAt — 완료 색상 반영을 위해 감시한다', () {
      final d = decide(linked(), linked(doneAt: DateTime.utc(2026, 8, 20, 15)));
      expect(d.kind, CalendarOpKind.update);
    });

    test('category — id 가 바뀌면 update (설명 문자열에 들어간다)', () {
      final d = decide(linked(), linked(category: Category.daily));
      expect(d.kind, CalendarOpKind.update);
    });

    test('recurrenceRule', () {
      final d = decide(
        linked(),
        linked(recurrenceRule: 'FREQ=DAILY;INTERVAL=1'),
      );
      expect(d.kind, CalendarOpKind.update);
    });

    test('recurrenceEndAt', () {
      final d = decide(
        linked(recurrenceRule: 'FREQ=DAILY;INTERVAL=1'),
        linked(
          recurrenceRule: 'FREQ=DAILY;INTERVAL=1',
          recurrenceEndAt: DateTime.utc(2026, 9, 30),
        ),
      );
      expect(d.kind, CalendarOpKind.update);
    });
  });

  group('비감시 필드 — 캘린더를 건드리지 않는다', () {
    test('sortOrder 만 바뀌면 none — 정렬 한 번에 API N회를 막는 핵심', () {
      final d = decide(linked(), linked(sortOrder: 7));
      expect(d.kind, CalendarOpKind.none);
    });

    test('parentId 만 바뀌면 none', () {
      final d = decide(linked(), linked(parentId: 'parent-9'));
      expect(d.kind, CalendarOpKind.none);
    });

    test('description 만 바뀌면 none', () {
      final d = decide(linked(), linked(description: '상세 메모'));
      expect(d.kind, CalendarOpKind.none);
    });

    test('category 의 label/색만 다르면 none — 표시 속성은 내용 변경이 아니다', () {
      final renamed = Category(
        id: Category.work.id,
        label: '다른 이름',
        iconCodePoint: 0xe000,
        colorValue: 0xFF000000,
      );
      final d = decide(linked(), linked(category: renamed));
      expect(d.kind, CalendarOpKind.none);
    });

    test('링크 필드만 바뀌면 none — 무한 재적재 방지', () {
      // 큐 flush 가 create 성공 후 calendarEventId 를 저장하면 그 upsert 가
      // 데코레이터를 다시 통과한다. 여기서 update 가 나오면 큐가 영원히 비지 않는다.
      final before = make(dueAt: DateTime.utc(2026, 8, 20, 14));
      final after = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        calendarEventId: 'ev-1',
        calendarId: writeCalendar,
      );
      expect(decide(before, after).kind, CalendarOpKind.none);
    });

    test('calendarOrigin 만 바뀌면 none', () {
      final before = linked();
      final after = linked().copyWith(calendarOrigin: 'gcal');
      expect(decide(before, after).kind, CalendarOpKind.none);
    });
  });

  group('삭제 — 링크가 있는데 캘린더에 있을 이유가 사라진 경우', () {
    test('dueAt 을 지우면 delete', () {
      final after = make(calendarEventId: 'ev-1', calendarId: writeCalendar);
      final d = decide(linked(), after);
      expect(d.kind, CalendarOpKind.delete);
      expect(d.eventId, 'ev-1');
    });

    test('메모(note)로 전환하면 delete', () {
      final d = decide(linked(), linked(type: TodoType.note));
      expect(d.kind, CalendarOpKind.delete);
      expect(d.eventId, 'ev-1');
    });

    test('delete 는 이벤트가 실제로 있는 캘린더를 대상으로 한다', () {
      final before = linked();
      final after = make(calendarEventId: 'ev-1', calendarId: 'other@calendar');
      expect(decide(before, after).calendarId, 'other@calendar');
    });
  });

  group('생성', () {
    test('신규 + dueAt + 토글 ON → create', () {
      final d = decide(null, make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      expect(d.kind, CalendarOpKind.create);
      expect(d.calendarId, writeCalendar);
      expect(d.eventId, isNull);
    });

    test('토글 OFF 면 만들지 않는다', () {
      final d = decide(
        null,
        make(dueAt: DateTime.utc(2026, 8, 20, 14)),
        addToCalendar: false,
      );
      expect(d.kind, CalendarOpKind.none);
    });

    test('dueAt 없으면 만들지 않는다', () {
      expect(decide(null, make()).kind, CalendarOpKind.none);
    });

    test('메모(note)는 만들지 않는다', () {
      final d = decide(
        null,
        make(dueAt: DateTime.utc(2026, 8, 20, 14), type: TodoType.note),
      );
      expect(d.kind, CalendarOpKind.none);
    });

    test('기존 항목에 dueAt 이 생기고 토글 ON → create', () {
      final d = decide(make(), make(dueAt: DateTime.utc(2026, 8, 20, 14)));
      expect(d.kind, CalendarOpKind.create);
    });
  });

  group('반복 시리즈 — 마스터만 이벤트를 소유한다', () {
    test('인스턴스는 create 하지 않는다 — 회차마다 이벤트가 생기는 사고 방지', () {
      final instance = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        seriesId: 'series-1',
      );
      expect(decide(null, instance).kind, CalendarOpKind.none);
    });

    test('마스터는 create 한다 (RRULE 이벤트 1개)', () {
      final master = make(
        dueAt: DateTime.utc(2026, 8, 20, 14),
        seriesId: 'todo-1',
        recurrenceRule: 'FREQ=DAILY;INTERVAL=1',
        isSeriesMaster: true,
      );
      expect(decide(null, master).kind, CalendarOpKind.create);
    });
  });

  group('원격에서 들어온 항목', () {
    test('prev 없이 링크만 있는 항목은 아무것도 하지 않는다', () {
      // 다른 기기가 만든 이벤트가 Supabase 를 타고 처음 도착한 경우.
      // 우리가 만든 변경이 아니므로 캘린더로 되쏘지 않는다.
      expect(decide(null, linked()).kind, CalendarOpKind.none);
    });
  });
}
