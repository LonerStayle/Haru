import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/data/local/app_database.dart';
import 'package:solo_todo/src/data/local/local_todo_repository.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/recurrence.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_controller.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_sheet.dart';

void main() {
  late AppDatabase db;
  late LocalTodoRepository repo;
  late AddTodoController controller;

  setUp(() {
    db = AppDatabase.memory();
    repo = LocalTodoRepository(db.todosDao);
    controller = AddTodoController(
      repo: repo,
      now: () => DateTime.utc(2026, 5, 27, 9, 0),
      calendar: null,
    );
  });

  tearDown(() async => db.close());

  test(
    'add() 가 Todo.create + repo.upsert 호출, 새 id 발급 + createdAt/updatedAt 주입',
    () async {
      final result = await controller.add(
        const AddTodoSubmission(
          title: '회의 정리',
          category: Category.work,
          dueAt: null,
          addToCalendar: false,
        ),
      );
      final created = result.todo;

      expect(created.title, '회의 정리');
      expect(created.category, Category.work);
      expect(created.createdAt, DateTime.utc(2026, 5, 27, 9, 0));
      expect(created.updatedAt, DateTime.utc(2026, 5, 27, 9, 0));
      expect(created.isDone, isFalse);
      expect(created.id, isNotEmpty);
      expect(result.calendarWarning, isNull);

      final fromDb = await repo.getById(created.id);
      expect(fromDb, created);
    },
  );

  test('dueAt 이 있으면 그대로 보존', () async {
    final due = DateTime(2026, 5, 28, 14, 30);
    final result = await controller.add(
      AddTodoSubmission(
        title: 'PR 리뷰',
        category: Category.personalDev,
        dueAt: due,
        addToCalendar: true,
      ),
    );

    expect(result.todo.dueAt, due);
  });

  test('서로 다른 호출은 서로 다른 id 발급 (uuid)', () async {
    final a = await controller.add(
      const AddTodoSubmission(
        title: 'a',
        category: Category.daily,
        dueAt: null,
        addToCalendar: false,
      ),
    );
    final b = await controller.add(
      const AddTodoSubmission(
        title: 'b',
        category: Category.daily,
        dueAt: null,
        addToCalendar: false,
      ),
    );

    expect(a.todo.id, isNot(b.todo.id));
  });

  test(
    'addToCalendar=true + calendar==null → calendarWarning 메시지 노출',
    () async {
      // setUp 의 controller.calendar 가 null — Google OAuth 미설정 상태 시뮬레이션.
      final result = await controller.add(
        AddTodoSubmission(
          title: 'cal',
          category: Category.work,
          dueAt: DateTime(2026, 5, 28, 14),
          addToCalendar: true,
        ),
      );

      expect(result.calendarWarning, isNotNull);
      expect(result.calendarWarning, contains('Calendar'));
    },
  );

  test('addToCalendar=false → calendarWarning == null (정상 케이스)', () async {
    final result = await controller.add(
      AddTodoSubmission(
        title: 'no cal',
        category: Category.work,
        dueAt: DateTime(2026, 5, 28, 14),
        addToCalendar: false,
      ),
    );
    expect(result.calendarWarning, isNull);
  });

  group('Task B — 신규 생성 sortOrder = min(형제)-1 (맨 위)', () {
    AddTodoSubmission sub(String title, {Category category = Category.work}) =>
        AddTodoSubmission(
          title: title,
          category: category,
          dueAt: null,
          addToCalendar: false,
        );

    test('형제 없으면 sortOrder = -1 (0 - 1)', () async {
      final r = await controller.add(sub('첫 항목'));
      expect(r.todo.sortOrder, -1);
    });

    test('연속 생성 → 각 신규가 min-1 로 맨 위', () async {
      final a = await controller.add(sub('A')); // -1
      final b = await controller.add(sub('B')); // min(-1)-1 = -2
      final c = await controller.add(sub('C')); // -3
      expect(a.todo.sortOrder, -1);
      expect(b.todo.sortOrder, -2);
      expect(c.todo.sortOrder, -3);
    });

    test('다른 카테고리는 형제 집합이 달라 독립 min', () async {
      await controller.add(sub('work-1')); // work: -1
      final d = await controller.add(sub('daily-1', category: Category.daily));
      expect(d.todo.sortOrder, -1, reason: 'daily 형제가 없으므로 0-1');
    });

    test('addAll — 입력 순서 보존 + 전체 맨 위 (첫 줄이 최상단)', () async {
      await controller.add(sub('기존')); // -1
      await controller.addAll([sub('첫'), sub('둘'), sub('셋')]);

      final list = await repo.watchByCategory(Category.work).first;
      // min=-1, n=3 → 첫=-4, 둘=-3, 셋=-2, 기존=-1. sortOrder asc → 첫,둘,셋,기존.
      expect(list.map((t) => t.title).toList(), ['첫', '둘', '셋', '기존']);
    });

    test('addAll — 반복 규칙이 있으면 건마다 반복 마스터로 저장 + 입력 순서 보존', () async {
      // UX 감사 B10 — 일괄 붙여넣기에서 반복 설정이 조용히 빠지던 문제.
      AddTodoSubmission rec(String title) => AddTodoSubmission(
        title: title,
        category: Category.work,
        dueAt: DateTime(2026, 5, 27),
        addToCalendar: false,
        recurrence: const RecurrenceRule(freq: RecurrenceFreq.daily),
      );
      await controller.addAll([rec('첫'), rec('둘')]);

      final all = await repo.watchAll().first;
      final masters = all.where((t) => t.isSeriesMaster).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      expect(masters.map((t) => t.title).toList(), ['첫', '둘']);
      expect(masters.every((t) => t.recurrenceRule != null), isTrue);
    });
  });
}
