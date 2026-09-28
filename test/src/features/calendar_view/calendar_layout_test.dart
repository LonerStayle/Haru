import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_layout.dart';

Todo make({
  required String id,
  String title = 't',
  Category category = Category.work,
  DateTime? dueAt,
  DateTime? endAt,
  bool isAllDay = false,
  DateTime? doneAt,
  int sortOrder = 0,
  DateTime? createdAt,
  TodoType type = TodoType.task,
}) => Todo(
  id: id,
  title: title,
  category: category,
  dueAt: dueAt,
  endAt: endAt,
  isAllDay: isAllDay,
  doneAt: doneAt,
  sortOrder: sortOrder,
  type: type,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
  updatedAt: createdAt ?? DateTime(2026, 1, 1),
);

void main() {
  group('monthGridDays — 6행 42칸 고정, 일요일 시작', () {
    test('항상 42칸', () {
      for (var m = 1; m <= 12; m++) {
        expect(monthGridDays(DateTime(2026, m)).length, 42, reason: '$m월');
      }
    });

    test('첫 칸은 항상 일요일, 마지막 칸은 항상 토요일', () {
      for (var m = 1; m <= 12; m++) {
        final days = monthGridDays(DateTime(2026, m));
        expect(days.first.weekday, DateTime.sunday, reason: '$m월 첫 칸');
        expect(days.last.weekday, DateTime.saturday, reason: '$m월 마지막 칸');
      }
    });

    test('2026-08 — 8/1(토) 이므로 앞에 7월 넘침 6칸', () {
      final days = monthGridDays(DateTime(2026, 8));
      expect(days.first, DateTime(2026, 7, 26));
      expect(days[6], DateTime(2026, 8, 1));
      // 8/1 이 토요일(열 6)에 놓인다.
      expect(days[6].weekday, DateTime.saturday);
      expect(days.last, DateTime(2026, 9, 5));
    });

    test('1일이 일요일인 달은 넘침 없이 1일부터 시작', () {
      // 2026-02-01 은 일요일.
      final days = monthGridDays(DateTime(2026, 2));
      expect(days.first, DateTime(2026, 2, 1));
    });

    test('달의 어느 날짜를 넣어도 같은 그리드', () {
      expect(
        monthGridDays(DateTime(2026, 8, 15)),
        monthGridDays(DateTime(2026, 8)),
      );
      expect(
        monthGridDays(DateTime(2026, 8, 31)),
        monthGridDays(DateTime(2026, 8)),
      );
    });

    test('연말 경계 — 12월 그리드가 다음 해로 넘어간다', () {
      final days = monthGridDays(DateTime(2026, 12));
      expect(days.any((d) => d.year == 2027), isTrue);
    });

    test('chunkIntoWeeks 는 7개씩 6주', () {
      final weeks = chunkIntoWeeks(monthGridDays(DateTime(2026, 8)));
      expect(weeks.length, 6);
      expect(weeks.every((w) => w.length == 7), isTrue);
    });
  });

  group('daysBetween', () {
    test('같은 날은 0, 하루 뒤는 1, 하루 앞은 -1', () {
      expect(daysBetween(DateTime(2026, 8, 15), DateTime(2026, 8, 15)), 0);
      expect(daysBetween(DateTime(2026, 8, 15), DateTime(2026, 8, 16)), 1);
      expect(daysBetween(DateTime(2026, 8, 15), DateTime(2026, 8, 14)), -1);
    });

    test('월·연 경계를 넘어도 정확', () {
      expect(daysBetween(DateTime(2026, 8, 31), DateTime(2026, 9, 1)), 1);
      expect(daysBetween(DateTime(2026, 12, 31), DateTime(2027, 1, 1)), 1);
    });
  });

  group('TodoEntry — 날짜 파생', () {
    test('endAt 없으면 startDate == endDate, 단일 항목', () {
      final e = TodoEntry(make(id: 'a', dueAt: DateTime(2026, 8, 15, 14, 30)));
      expect(e.startDate, DateTime(2026, 8, 15));
      expect(e.endDate, DateTime(2026, 8, 15));
      expect(e.spansMultipleDays, isFalse);
    });

    test('endAt 있으면 기간 — 시각은 날짜로 절삭', () {
      final e = TodoEntry(
        make(
          id: 'a',
          dueAt: DateTime(2026, 8, 15, 9),
          endAt: DateTime(2026, 8, 18, 18),
        ),
      );
      expect(e.startDate, DateTime(2026, 8, 15));
      expect(e.endDate, DateTime(2026, 8, 18));
      expect(e.spansMultipleDays, isTrue);
    });

    test('endAt 이 dueAt 보다 앞선 뒤집힌 데이터는 단일로 접는다', () {
      // span 이 음수가 되면 막대 레이아웃이 통째로 깨지므로 엔트리에서 한 번만 막는다.
      final e = TodoEntry(
        make(
          id: 'a',
          dueAt: DateTime(2026, 8, 15),
          endAt: DateTime(2026, 8, 10),
        ),
      );
      expect(e.endDate, DateTime(2026, 8, 15));
      expect(e.spansMultipleDays, isFalse);
    });

    test('종일이면 timeAnchorAt 이 null (시각을 정렬에도 안 쓴다)', () {
      final allDay = TodoEntry(
        make(id: 'a', dueAt: DateTime(2026, 8, 15), isAllDay: true),
      );
      final timed = TodoEntry(
        make(id: 'b', dueAt: DateTime(2026, 8, 15, 9, 30)),
      );
      expect(allDay.timeAnchorAt, isNull);
      expect(timed.timeAnchorAt, DateTime(2026, 8, 15, 9, 30));
    });

    test('entryKey 는 todo: 접두어 + id', () {
      expect(
        TodoEntry(make(id: 'abc', dueAt: DateTime(2026, 8, 15))).entryKey,
        'todo:abc',
      );
    });
  });

  group('RecurringGhostEntry', () {
    Todo master({
      DateTime? dueAt,
      DateTime? endAt,
      bool isAllDay = false,
      String seriesId = 's1',
    }) => make(
      id: seriesId,
      dueAt: dueAt ?? DateTime(2026, 8, 3, 10),
      endAt: endAt,
      isAllDay: isAllDay,
    ).copyWith(seriesId: seriesId, isSeriesMaster: true);

    test('단일 마스터의 고스트는 하루짜리', () {
      final g = RecurringGhostEntry(
        master: master(),
        date: DateTime(2026, 8, 17),
      );
      expect(g.startDate, DateTime(2026, 8, 17));
      expect(g.endDate, DateTime(2026, 8, 17));
      expect(g.isGhost, isTrue);
      expect(g.isDone, isFalse);
    });

    test('기간 마스터의 고스트는 같은 길이를 유지', () {
      final g = RecurringGhostEntry(
        master: master(
          dueAt: DateTime(2026, 8, 3, 9),
          endAt: DateTime(2026, 8, 5, 18),
        ),
        date: DateTime(2026, 8, 17),
      );
      expect(g.startDate, DateTime(2026, 8, 17));
      expect(g.endDate, DateTime(2026, 8, 19));
      expect(g.spansMultipleDays, isTrue);
    });

    test('시각은 마스터에서 이어받고 날짜만 회차의 것', () {
      final g = RecurringGhostEntry(
        master: master(dueAt: DateTime(2026, 8, 3, 10, 15)),
        date: DateTime(2026, 8, 17),
      );
      expect(g.timeAnchorAt, DateTime(2026, 8, 17, 10, 15));
    });

    test('entryKey 는 실체화 id 규약(seriesId#yyyymmdd)과 같은 날짜 표기', () {
      final g = RecurringGhostEntry(
        master: master(seriesId: 'sid'),
        date: DateTime(2026, 8, 7),
      );
      expect(g.entryKey, 'ghost:sid#20260807');
    });
  });

  group('GoogleEventEntry', () {
    test('읽기 전용 — 드래그 불가, 완료 개념 없음', () {
      final e = GoogleEventEntry(
        id: 'g1',
        title: '팀 미팅',
        start: DateTime(2026, 8, 15, 14),
        end: DateTime(2026, 8, 15, 15),
        isAllDay: false,
      );
      expect(e.isDraggable, isFalse);
      expect(e.isDone, isFalse);
      expect(e.isGhost, isFalse);
      expect(e.entryKey, 'gcal:g1');
      expect(e.color, GoogleEventEntry.eventColor);
    });

    test('여러 날 이벤트는 기간으로 잡힌다', () {
      final e = GoogleEventEntry(
        id: 'g2',
        title: '휴가',
        start: DateTime(2026, 8, 10),
        end: DateTime(2026, 8, 14),
        isAllDay: true,
      );
      expect(e.spansMultipleDays, isTrue);
      expect(e.startDate, DateTime(2026, 8, 10));
      expect(e.endDate, DateTime(2026, 8, 14));
    });
  });

  group('bucketByDate', () {
    test('단일 항목은 그 날짜 하나에만 들어간다', () {
      final e = TodoEntry(make(id: 'a', dueAt: DateTime(2026, 8, 15)));
      final buckets = bucketByDate(
        entries: [e],
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
      );
      expect(buckets.keys, [DateTime(2026, 8, 15)]);
      expect(buckets[DateTime(2026, 8, 15)], [e]);
    });

    test('기간 항목은 걸친 모든 날짜에 들어간다', () {
      final e = TodoEntry(
        make(
          id: 'a',
          dueAt: DateTime(2026, 8, 15),
          endAt: DateTime(2026, 8, 18),
        ),
      );
      final buckets = bucketByDate(
        entries: [e],
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
      );
      expect(buckets.length, 4);
      for (var d = 15; d <= 18; d++) {
        expect(buckets[DateTime(2026, 8, d)], contains(e), reason: '8/$d');
      }
    });

    test('범위 밖은 잘라낸다 — 걸쳐 있으면 겹치는 부분만', () {
      final e = TodoEntry(
        make(
          id: 'a',
          dueAt: DateTime(2026, 7, 28),
          endAt: DateTime(2026, 8, 3),
        ),
      );
      final buckets = bucketByDate(
        entries: [e],
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
      );
      expect(buckets.keys.toList()..sort(), [
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 2),
        DateTime(2026, 8, 3),
      ]);
    });

    test('범위와 전혀 안 겹치면 아예 안 들어간다', () {
      final e = TodoEntry(make(id: 'a', dueAt: DateTime(2026, 6, 1)));
      final buckets = bucketByDate(
        entries: [e],
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
      );
      expect(buckets, isEmpty);
    });
  });

  group('compareEntries — 칸 안 표시 순서', () {
    TodoEntry todo({
      required String id,
      DateTime? dueAt,
      DateTime? endAt,
      bool isAllDay = false,
      bool done = false,
      int sortOrder = 0,
    }) => TodoEntry(
      make(
        id: id,
        dueAt: dueAt ?? DateTime(2026, 8, 15, 12),
        endAt: endAt,
        isAllDay: isAllDay,
        doneAt: done ? DateTime(2026, 8, 15, 20) : null,
        sortOrder: sortOrder,
      ),
    );

    test('기간 막대가 단일 항목보다 앞', () {
      final bar = todo(
        id: 'bar',
        dueAt: DateTime(2026, 8, 14),
        endAt: DateTime(2026, 8, 16),
      );
      final single = todo(id: 'single');
      final list = [single, bar]..sort(compareEntries);
      expect(list.first, bar);
    });

    test('미완료가 완료보다 앞 — 칸 상한을 완료가 먹지 않도록', () {
      final done = todo(
        id: 'done',
        done: true,
        dueAt: DateTime(2026, 8, 15, 8),
      );
      final undone = todo(id: 'undone', dueAt: DateTime(2026, 8, 15, 18));
      final list = [done, undone]..sort(compareEntries);
      expect(list.first, undone);
    });

    test('종일이 시각 있는 항목보다 앞', () {
      final timed = todo(id: 'timed', dueAt: DateTime(2026, 8, 15, 9));
      final allDay = todo(id: 'allday', isAllDay: true);
      final list = [timed, allDay]..sort(compareEntries);
      expect(list.first, allDay);
    });

    test('시각 있는 항목끼리는 이른 시각 먼저', () {
      final late = todo(id: 'late', dueAt: DateTime(2026, 8, 15, 18));
      final early = todo(id: 'early', dueAt: DateTime(2026, 8, 15, 9));
      final list = [late, early]..sort(compareEntries);
      expect(list.map((e) => e.entryKey), ['todo:early', 'todo:late']);
    });

    test('같은 시각이면 sortOrder asc', () {
      final b = todo(id: 'b', sortOrder: 5);
      final a = todo(id: 'a', sortOrder: 1);
      final list = [b, a]..sort(compareEntries);
      expect(list.first, a);
    });

    test('정렬은 updatedAt 에 반응하지 않는다', () {
      // 체크·동기화로 updatedAt 만 바뀌었을 때 자리가 튀면 안 된다.
      final base = make(
        id: 'x',
        dueAt: DateTime(2026, 8, 15, 9),
        createdAt: DateTime(2026, 1, 1),
      );
      final touched = base.copyWith(updatedAt: DateTime(2026, 8, 15, 23));
      final other = TodoEntry(
        make(
          id: 'y',
          dueAt: DateTime(2026, 8, 15, 10),
          createdAt: DateTime(2026, 1, 1),
        ),
      );
      final before = [TodoEntry(base), other]..sort(compareEntries);
      final after = [TodoEntry(touched), other]..sort(compareEntries);
      expect(
        after.map((e) => e.entryKey).toList(),
        before.map((e) => e.entryKey).toList(),
      );
    });
  });

  group('layoutWeekBars — 기간 막대 레인 배치', () {
    // 2026-08-16(일) ~ 2026-08-22(토) 주.
    final weekStart = DateTime(2026, 8, 16);

    TodoEntry bar(String id, int startDay, int endDay) => TodoEntry(
      make(
        id: id,
        dueAt: DateTime(2026, 8, startDay),
        endAt: DateTime(2026, 8, endDay),
      ),
    );

    test('단일 항목은 막대로 잡히지 않는다', () {
      final single = TodoEntry(make(id: 's', dueAt: DateTime(2026, 8, 18)));
      expect(layoutWeekBars([single], weekStart), isEmpty);
    });

    test('주 안에 온전히 들어가는 막대 — 열/폭 계산', () {
      final segs = layoutWeekBars([bar('a', 17, 19)], weekStart);
      expect(segs.length, 1);
      expect(segs.single.startCol, 1); // 8/17 은 월요일
      expect(segs.single.span, 3); // 17,18,19
      expect(segs.single.endCol, 3);
      expect(segs.single.lane, 0);
      expect(segs.single.continuesLeft, isFalse);
      expect(segs.single.continuesRight, isFalse);
    });

    test('주 경계를 넘으면 잘리고 이어짐 표식이 붙는다', () {
      // 8/14(금) ~ 8/25(화) — 앞뒤 양쪽으로 넘친다.
      final segs = layoutWeekBars([bar('a', 14, 25)], weekStart);
      expect(segs.single.startCol, 0);
      expect(segs.single.span, 7);
      expect(segs.single.continuesLeft, isTrue);
      expect(segs.single.continuesRight, isTrue);
    });

    test('겹치는 막대는 다른 레인으로 내려간다', () {
      final segs = layoutWeekBars([
        bar('a', 17, 19),
        bar('b', 18, 21),
      ], weekStart);
      final byId = {for (final s in segs) s.entry.entryKey: s};
      expect(byId['todo:a']!.lane, 0);
      expect(byId['todo:b']!.lane, 1);
    });

    test('겹치지 않는 막대는 같은 레인을 재사용한다', () {
      final segs = layoutWeekBars([
        bar('a', 16, 17),
        bar('b', 20, 22),
      ], weekStart);
      expect(segs.every((s) => s.lane == 0), isTrue);
    });

    test('이 주와 무관한 막대는 제외', () {
      expect(layoutWeekBars([bar('a', 1, 3)], weekStart), isEmpty);
      expect(layoutWeekBars([bar('a', 24, 28)], weekStart), isEmpty);
    });

    test('한 주에 막대가 많아도 레인 배치가 폭주하지 않는다', () {
      // 겹치는 막대 30개 → 레인 30개. 위젯 쪽 상한이 자르더라도 계산은 끝나야 한다.
      final many = [for (var i = 0; i < 30; i++) bar('b$i', 17, 20)];
      final segs = layoutWeekBars(many, weekStart);
      expect(segs, hasLength(30));
      expect(segs.map((s) => s.lane).toSet(), hasLength(30));
    });

    test('같은 입력이면 항상 같은 배치 (레이아웃이 프레임마다 튀지 않도록)', () {
      final entries = [bar('c', 18, 21), bar('a', 17, 19), bar('b', 17, 22)];
      final first = layoutWeekBars(entries, weekStart);
      final second = layoutWeekBars(entries.reversed, weekStart);
      String sig(List<BarSegment> segs) =>
          (segs
                  .map(
                    (s) =>
                        '${s.entry.entryKey}@${s.lane}:${s.startCol}+${s.span}',
                  )
                  .toList()
                ..sort())
              .join(',');
      expect(sig(second), sig(first));
    });
  });

  group('성능 sanity — 한 달 그리기가 프레임을 넘기지 않는다', () {
    // 이 앱은 1인 사용자 데이터(수백 건)를 전부 in-memory 로 다룬다. 그래서
    // "달을 넘길 때마다 전체를 다시 버킷팅" 이 성립하는지 상한으로 못 박아둔다.
    test('2000건을 42칸으로 버킷팅 + 주별 막대 배치', () {
      final entries = [
        for (var i = 0; i < 2000; i++)
          TodoEntry(
            make(
              id: 'e$i',
              dueAt: DateTime(2026, 8, 1 + (i % 31), 9 + (i % 12)),
              // 5건 중 1건은 기간 항목 (막대 배치까지 태운다).
              endAt: i % 5 == 0 ? DateTime(2026, 8, 3 + (i % 28)) : null,
            ),
          ),
      ];

      final sw = Stopwatch()..start();
      final buckets = bucketByDate(
        entries: entries,
        rangeStart: DateTime(2026, 7, 26),
        rangeEnd: DateTime(2026, 9, 5),
      );
      for (final week in chunkIntoWeeks(monthGridDays(DateTime(2026, 8)))) {
        layoutWeekBars(
          week.expand((d) => buckets[d] ?? const <CalendarEntry>[]).toSet(),
          week.first,
        );
      }
      sw.stop();

      expect(buckets, isNotEmpty);
      // 60fps 프레임 예산(16.7ms)의 여러 배를 잡아 느슨하게 — 회귀 감지용 상한.
      expect(
        sw.elapsedMilliseconds,
        lessThan(200),
        reason: '한 달 렌더 준비가 200ms 를 넘으면 달 넘김이 눈에 띄게 끊긴다',
      );
    });
  });
}
