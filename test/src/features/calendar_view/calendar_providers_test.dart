import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/domain/recurrence_materializer.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_providers.dart';
import 'package:solo_todo/src/features/category/categories_controller.dart';
import 'package:solo_todo/src/features/outline/tree_providers.dart';

Todo make({
  required String id,
  String title = 't',
  Category? category,
  DateTime? dueAt,
  DateTime? endAt,
  bool isAllDay = false,
  DateTime? doneAt,
  TodoType type = TodoType.task,
  int sortOrder = 0,
  DateTime? createdAt,
}) => Todo(
  id: id,
  title: title,
  category: category ?? Category.work,
  dueAt: dueAt,
  endAt: endAt,
  isAllDay: isAllDay,
  doneAt: doneAt,
  type: type,
  sortOrder: sortOrder,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
  updatedAt: createdAt ?? DateTime(2026, 1, 1),
);

Todo recurringMaster({
  String id = 'm1',
  required DateTime anchor,
  RecurrenceFreq freq = RecurrenceFreq.weekly,
  DateTime? recurrenceEndAt,
  Category? category,
}) => make(id: id, dueAt: anchor, category: category).copyWith(
  seriesId: id,
  recurrenceRule: RecurrenceRule(freq: freq).encode(),
  recurrenceEndAt: recurrenceEndAt,
  isSeriesMaster: true,
);

void main() {
  final august = CalendarRange.forMonth(DateTime(2026, 8));
  final now = DateTime(2026, 8, 15, 12);

  group('CalendarRange', () {
    test('forMonth 은 6주 그리드 전체를 덮는다', () {
      expect(august.start, DateTime(2026, 7, 26));
      expect(august.end, DateTime(2026, 9, 5));
    });

    test('값 동등 — 같은 달이면 같은 family 키 (캐시가 매번 날아가지 않도록)', () {
      expect(CalendarRange.forMonth(DateTime(2026, 8, 1)), august);
      expect(CalendarRange.forMonth(DateTime(2026, 8, 31)), august);
      expect(
        CalendarRange.forMonth(DateTime(2026, 8, 1)).hashCode,
        august.hashCode,
      );
      expect(CalendarRange.forMonth(DateTime(2026, 9)), isNot(august));
    });

    test('시각 성분은 잘라낸다', () {
      final r = CalendarRange(
        DateTime(2026, 8, 1, 13),
        DateTime(2026, 8, 5, 9),
      );
      expect(r.start, DateTime(2026, 8, 1));
      expect(r.end, DateTime(2026, 8, 5));
    });
  });

  group('buildCalendarEntries — 필터', () {
    test('날짜 있는 Todo 만 엔트리가 된다', () {
      final entries = buildCalendarEntries(
        all: [
          make(id: 'dated', dueAt: DateTime(2026, 8, 15)),
          make(id: 'undated'),
        ],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(entries.map((e) => e.entryKey), ['todo:dated']);
    });

    test('반복 마스터는 제외 — anchor 날짜에 유령이 뜨면 안 된다', () {
      final master = recurringMaster(anchor: DateTime(2026, 8, 3, 10));
      final entries = buildCalendarEntries(
        all: [master],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(
        entries.whereType<TodoEntry>().map((e) => e.todo.id),
        isNot(contains('m1')),
      );
    });

    test('보관 카테고리의 항목은 제외', () {
      final entries = buildCalendarEntries(
        all: [
          make(id: 'a', dueAt: DateTime(2026, 8, 15), category: Category.work),
          make(id: 'b', dueAt: DateTime(2026, 8, 15), category: Category.daily),
        ],
        archivedIds: {Category.work.id},
        range: august,
        now: now,
      );
      expect(entries.map((e) => e.entryKey), ['todo:b']);
    });

    test('메모(note) 도 날짜가 있으면 표시한다', () {
      final entries = buildCalendarEntries(
        all: [make(id: 'n', dueAt: DateTime(2026, 8, 15), type: TodoType.note)],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(entries.map((e) => e.entryKey), ['todo:n']);
    });

    test('완료 항목도 표시한다 (흐리게 그리는 건 위젯 몫)', () {
      final entries = buildCalendarEntries(
        all: [
          make(
            id: 'done',
            dueAt: DateTime(2026, 8, 15),
            doneAt: DateTime(2026, 8, 15, 20),
          ),
        ],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(entries.single.isDone, isTrue);
    });

    test('범위 밖 날짜의 Todo 도 엔트리는 만든다 (버킷팅에서 잘린다)', () {
      // 화면 범위 판단은 bucketByDate 한 곳에서만 하도록 책임을 나눈다.
      final entries = buildCalendarEntries(
        all: [make(id: 'far', dueAt: DateTime(2027, 1, 1))],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(entries, hasLength(1));
    });
  });

  group('buildRecurringGhosts — 미래 회차만', () {
    test('오늘 이후 발생일만 고스트로 만든다', () {
      // anchor 8/1(토), 매주 토 → 8/1, 8/8, 8/15, 8/22, 8/29. 오늘은 8/15.
      final m = recurringMaster(anchor: DateTime(2026, 8, 1, 10));
      final ghosts = buildRecurringGhosts(
        all: [m],
        archivedIds: const {},
        range: august,
        now: now,
      );
      // 9/5 는 다음 달이지만 8월 그리드의 마지막 칸이라 함께 그린다.
      expect(ghosts.map((g) => g.startDate), [
        DateTime(2026, 8, 22),
        DateTime(2026, 8, 29),
        DateTime(2026, 9, 5),
      ]);
    });

    test('이미 실체화된 날짜는 고스트를 만들지 않는다 (겹쳐 보이지 않도록)', () {
      final m = recurringMaster(anchor: DateTime(2026, 8, 1, 10));
      final materialized = RecurrenceMaterializer.materializeOne(
        m,
        DateTime(2026, 8, 22),
        now,
      )!;
      final ghosts = buildRecurringGhosts(
        all: [m, materialized],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(ghosts.map((g) => g.startDate), [
        DateTime(2026, 8, 29),
        DateTime(2026, 9, 5),
      ]);
    });

    test('반복 종료일 이후는 만들지 않는다', () {
      final m = recurringMaster(
        anchor: DateTime(2026, 8, 1, 10),
        recurrenceEndAt: DateTime(2026, 8, 25),
      );
      final ghosts = buildRecurringGhosts(
        all: [m],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(ghosts.map((g) => g.startDate), [DateTime(2026, 8, 22)]);
    });

    test('범위 밖으로는 만들지 않는다', () {
      final m = recurringMaster(
        anchor: DateTime(2026, 8, 1, 10),
        freq: RecurrenceFreq.daily,
      );
      final ghosts = buildRecurringGhosts(
        all: [m],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(ghosts.every((g) => !g.startDate.isAfter(august.end)), isTrue);
      expect(ghosts.every((g) => !g.startDate.isBefore(august.start)), isTrue);
    });

    test('보관 카테고리의 반복은 고스트도 안 만든다', () {
      final m = recurringMaster(
        anchor: DateTime(2026, 8, 1, 10),
        category: Category.work,
      );
      expect(
        buildRecurringGhosts(
          all: [m],
          archivedIds: {Category.work.id},
          range: august,
          now: now,
        ),
        isEmpty,
      );
    });

    test('anchor 이전으로는 거슬러 올라가지 않는다', () {
      final m = recurringMaster(
        anchor: DateTime(2026, 8, 29, 10),
        freq: RecurrenceFreq.daily,
      );
      final ghosts = buildRecurringGhosts(
        all: [m],
        archivedIds: const {},
        range: august,
        now: now,
      );
      expect(ghosts.map((g) => g.startDate), [
        DateTime(2026, 8, 29),
        DateTime(2026, 8, 30),
        DateTime(2026, 8, 31),
        DateTime(2026, 9, 1),
        DateTime(2026, 9, 2),
        DateTime(2026, 9, 3),
        DateTime(2026, 9, 4),
        DateTime(2026, 9, 5),
      ]);
    });

    test('반복이 없으면 빈 리스트', () {
      expect(
        buildRecurringGhosts(
          all: [make(id: 'a', dueAt: DateTime(2026, 8, 15))],
          archivedIds: const {},
          range: august,
          now: now,
        ),
        isEmpty,
      );
    });
  });

  group('buildUndatedTodos — 날짜 없음 서랍', () {
    test('날짜 없는 미완료 할 일만', () {
      final list = buildUndatedTodos(
        all: [
          make(id: 'keep'),
          make(id: 'dated', dueAt: DateTime(2026, 8, 15)),
          make(id: 'done', doneAt: DateTime(2026, 8, 1)),
          make(id: 'note', type: TodoType.note),
          recurringMaster(anchor: DateTime(2026, 8, 1)),
        ],
        archivedIds: const {},
      );
      expect(list.map((t) => t.id), ['keep']);
    });

    test('보관 카테고리 제외', () {
      final list = buildUndatedTodos(
        all: [
          make(id: 'a', category: Category.work),
          make(id: 'b', category: Category.daily),
        ],
        archivedIds: {Category.work.id},
      );
      expect(list.map((t) => t.id), ['b']);
    });

    test('sortOrder asc → createdAt desc → id asc 순서', () {
      final list = buildUndatedTodos(
        all: [
          make(id: 'c', sortOrder: 2),
          make(id: 'a', sortOrder: 1, createdAt: DateTime(2026, 1, 1)),
          make(id: 'b', sortOrder: 1, createdAt: DateTime(2026, 5, 1)),
        ],
        archivedIds: const {},
      );
      // sortOrder 1 그룹에서 createdAt 이 최신인 b 가 먼저.
      expect(list.map((t) => t.id), ['b', 'a', 'c']);
    });
  });

  group('provider 배선', () {
    ProviderContainer container(List<Todo> todos) {
      final c = ProviderContainer(
        overrides: [
          allTodosProvider.overrideWith((_) => Stream.value(todos)),
          categoriesProvider.overrideWith(
            (_) => Stream.value(Category.builtinSeeds),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('calendarBucketsProvider 가 날짜별로 정리된 버킷을 낸다', () async {
      final c = container([
        make(id: 'a', dueAt: DateTime(2026, 8, 15, 9)),
        make(
          id: 'span',
          dueAt: DateTime(2026, 8, 14),
          endAt: DateTime(2026, 8, 16),
          isAllDay: true,
        ),
      ]);

      // stream 이 흐를 때까지 대기 (기존 provider 테스트와 같은 listen + flush 관용구).
      c.listen(allTodosProvider, (_, _) {});
      await pumpEventQueue();
      final buckets = c.read(calendarBucketsProvider(august)).requireValue;

      expect(buckets[DateTime(2026, 8, 15)], hasLength(2));
      // 기간 막대가 먼저.
      expect(buckets[DateTime(2026, 8, 15)]!.first.entryKey, 'todo:span');
      expect(buckets[DateTime(2026, 8, 14)], hasLength(1));
      expect(buckets[DateTime(2026, 8, 17)], isNull);
    });

    test('calendarUndatedTodosProvider 가 서랍 목록을 낸다', () async {
      final c = container([
        make(id: 'u1'),
        make(id: 'd1', dueAt: DateTime(2026, 8, 15)),
      ]);
      c.listen(allTodosProvider, (_, _) {});
      await pumpEventQueue();
      expect(
        c.read(calendarUndatedTodosProvider).requireValue.map((t) => t.id),
        ['u1'],
      );
    });
  });
}
