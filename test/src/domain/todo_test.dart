import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  // 결정적 시간 / id 주입 — DateTime.now / Uuid().v4 가 호출되지 않게 한다.
  DateTime fixedNow() => DateTime.utc(2026, 5, 27, 9, 0, 0);
  String fixedId() => '00000000-0000-4000-8000-000000000001';

  group('Todo.create', () {
    test('필수 필드 + dueAt null, doneAt null, calendarEventId null 로 초기화', () {
      final t = Todo.create(
        title: '회사 보고서',
        category: Category.work,
        now: fixedNow,
        idGen: fixedId,
      );

      expect(t.id, fixedId());
      expect(t.title, '회사 보고서');
      expect(t.category, Category.work);
      expect(t.dueAt, isNull);
      expect(t.doneAt, isNull);
      expect(t.createdAt, fixedNow());
      expect(t.updatedAt, fixedNow());
      expect(t.calendarEventId, isNull);
      expect(t.isDone, isFalse);
    });

    test('dueAt 전달 시 보존', () {
      final due = DateTime.utc(2026, 5, 28, 14, 0);
      final t = Todo.create(
        title: '미팅',
        category: Category.work,
        dueAt: due,
        now: fixedNow,
        idGen: fixedId,
      );
      expect(t.dueAt, due);
    });
  });

  group('Todo.toggleDone', () {
    test('미체크 → 체크: doneAt 가 [now] 가 되고 updatedAt 도 갱신', () {
      final t = Todo.create(
        title: 'x',
        category: Category.daily,
        now: () => DateTime.utc(2026, 5, 1),
        idGen: fixedId,
      );
      final later = DateTime.utc(2026, 5, 27, 10);
      final toggled = t.toggleDone(now: () => later);

      expect(toggled.isDone, isTrue);
      expect(toggled.doneAt, later);
      expect(toggled.updatedAt, later);
      // 다른 필드는 보존
      expect(toggled.id, t.id);
      expect(toggled.title, t.title);
      expect(toggled.createdAt, t.createdAt);
    });

    test('체크 → 미체크: doneAt 가 null 로, updatedAt 은 갱신', () {
      final created = DateTime.utc(2026, 5, 1);
      final base = Todo.create(
        title: 'x',
        category: Category.daily,
        now: () => created,
        idGen: fixedId,
      );
      final firstToggle = DateTime.utc(2026, 5, 2);
      final done = base.toggleDone(now: () => firstToggle);

      final undoTime = DateTime.utc(2026, 5, 3);
      final undone = done.toggleDone(now: () => undoTime);
      expect(undone.isDone, isFalse);
      expect(undone.doneAt, isNull);
      expect(undone.updatedAt, undoTime);
    });
  });

  group('진행중 3-상태 — startedAt / isInProgress / toggleInProgress', () {
    Todo fresh() => Todo.create(
      title: 'x',
      category: Category.daily,
      now: () => DateTime.utc(2026, 5, 1),
      idGen: fixedId,
    );

    test('Todo.create 는 startedAt null (미완료)', () {
      final t = fresh();
      expect(t.startedAt, isNull);
      expect(t.isInProgress, isFalse);
      expect(t.isDone, isFalse);
    });

    test('미완료 → 진행중: startedAt 세팅, doneAt null 유지', () {
      final at = DateTime.utc(2026, 5, 27, 10);
      final ip = fresh().toggleInProgress(now: () => at);
      expect(ip.isInProgress, isTrue);
      expect(ip.isDone, isFalse);
      expect(ip.startedAt, at);
      expect(ip.doneAt, isNull);
      expect(ip.updatedAt, at);
    });

    test('진행중 → 미완료: 다시 토글하면 startedAt null', () {
      final ip = fresh().toggleInProgress(now: () => DateTime.utc(2026, 5, 27));
      final undone = ip.toggleInProgress(now: () => DateTime.utc(2026, 5, 28));
      expect(undone.isInProgress, isFalse);
      expect(undone.startedAt, isNull);
      expect(undone.doneAt, isNull);
    });

    test('진행중 → 완료: 완료 시 startedAt 제거 (완료 = 진행중 아님)', () {
      final ip = fresh().toggleInProgress(now: () => DateTime.utc(2026, 5, 27));
      final done = ip.toggleDone(now: () => DateTime.utc(2026, 5, 28, 12));
      expect(done.isDone, isTrue);
      expect(done.isInProgress, isFalse);
      expect(done.startedAt, isNull, reason: '완료 시 진행중 표식 제거');
      expect(done.doneAt, DateTime.utc(2026, 5, 28, 12));
    });

    test('완료 → 진행중: 진행중 토글 시 doneAt 해제 (불변식: 동시 세팅 금지)', () {
      final done = fresh().toggleDone(now: () => DateTime.utc(2026, 5, 27));
      final ip = done.toggleInProgress(now: () => DateTime.utc(2026, 5, 28));
      expect(ip.isInProgress, isTrue);
      expect(ip.isDone, isFalse);
      expect(ip.doneAt, isNull);
      expect(ip.startedAt, DateTime.utc(2026, 5, 28));
    });

    test('완료 해제 → 미완료 (startedAt 이미 없음)', () {
      final done = fresh().toggleDone(now: () => DateTime.utc(2026, 5, 27));
      final undone = done.toggleDone(now: () => DateTime.utc(2026, 5, 28));
      expect(undone.isDone, isFalse);
      expect(undone.isInProgress, isFalse);
      expect(undone.startedAt, isNull);
      expect(undone.doneAt, isNull);
    });

    test('note 는 toggleInProgress 무시 (진행 개념 없음)', () {
      final note = Todo.create(
        title: '메모',
        category: Category.idea,
        now: fixedNow,
        idGen: fixedId,
        type: TodoType.note,
      );
      final toggled = note.toggleInProgress(
        now: () => DateTime.utc(2026, 5, 28),
      );
      expect(toggled, note);
      expect(
        note.copyWith(startedAt: DateTime.utc(2026, 5, 28)).isInProgress,
        isFalse,
      );
    });

    test('JSON round-trip — startedAt 보존', () {
      final ip = fresh().toggleInProgress(now: () => DateTime.utc(2026, 5, 27));
      expect(Todo.fromJson(ip.toJson()), ip);
    });

    test('JSON 역호환 — startedAt 누락 → null (미완료)', () {
      final legacyJson = <String, dynamic>{
        'id': 'legacy',
        'title': '옛 todo',
        'category': 'work',
        'dueAt': null,
        'doneAt': null,
        'createdAt': '2026-05-01T09:00:00.000Z',
        'updatedAt': '2026-05-01T09:00:00.000Z',
        'calendarEventId': null,
      };
      final restored = Todo.fromJson(legacyJson);
      expect(restored.startedAt, isNull);
      expect(restored.isInProgress, isFalse);
    });
  });

  test('withCalendarEvent 가 eventId 와 updatedAt 만 변경', () {
    final t = Todo.create(
      title: 'x',
      category: Category.idea,
      now: fixedNow,
      idGen: fixedId,
    );
    final later = DateTime.utc(2026, 5, 28);
    final linked = t.withCalendarEvent('event-123', now: () => later);
    expect(linked.calendarEventId, 'event-123');
    expect(linked.updatedAt, later);
    expect(linked.id, t.id);
    expect(linked.title, t.title);
    expect(linked.createdAt, t.createdAt);
  });

  group('JSON round-trip', () {
    test('완전 필드 (dueAt / doneAt / calendarEventId 모두 채움)', () {
      final original = Todo(
        id: 'abc',
        title: 'PR 리뷰',
        category: Category.personalDev,
        dueAt: DateTime.utc(2026, 5, 28, 13),
        doneAt: DateTime.utc(2026, 5, 28, 18),
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 28, 18),
        calendarEventId: 'evt-xyz',
      );
      final json = original.toJson();
      // 카테고리는 [Category.id] 그대로 직렬화 — @JsonValue('personal_dev') 보장.
      expect(json['category'], 'personal_dev');

      final restored = Todo.fromJson(json);
      expect(restored, original);
    });

    test('nullable 필드 누락 round-trip', () {
      final original = Todo.create(
        title: '아이디어',
        category: Category.idea,
        now: fixedNow,
        idGen: fixedId,
      );
      final restored = Todo.fromJson(original.toJson());
      expect(restored, original);
    });

    test('사용자 추가 카테고리 id 보존 — 일상(daily)으로 붕괴하지 않는다', () {
      // v1.2 사용자 정의 카테고리. builtin 5종이 아니므로 tryFromId 가 null.
      // outbox flush 가 toJson→fromJson 으로 복원할 때 이 id 가 보존돼야 한다.
      // 붕괴되면 Supabase 에 'daily' 로 업로드되어 다른 기기에서 전부 일상으로 보인다.
      const custom = Category(
        id: 'cat-abc123',
        label: '운동',
        iconCodePoint: 0xe1a3,
        colorValue: 0xFF00BCD4,
      );
      final original = Todo(
        id: 'u1',
        title: '러닝 5km',
        category: custom,
        dueAt: null,
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 31, 9),
        updatedAt: DateTime.utc(2026, 5, 31, 9),
        calendarEventId: null,
      );

      final json = original.toJson();
      expect(json['category'], 'cat-abc123');

      final restored = Todo.fromJson(json);
      expect(
        restored.category.id,
        'cat-abc123',
        reason: '사용자 카테고리 id 가 daily 로 붕괴되면 안 됨 (서버 데이터 오염 원인)',
      );
    });
  });

  test('Equality (freezed) — 동일 필드는 ==', () {
    final a = Todo.create(
      title: 'a',
      category: Category.daily,
      now: fixedNow,
      idGen: fixedId,
    );
    final b = Todo.create(
      title: 'a',
      category: Category.daily,
      now: fixedNow,
      idGen: fixedId,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  group('v1.1 — parentId / type / sortOrder', () {
    test('Todo.create 기본값 — parentId null, type task, sortOrder 0', () {
      final t = Todo.create(
        title: 'x',
        category: Category.daily,
        now: fixedNow,
        idGen: fixedId,
      );
      expect(t.parentId, isNull);
      expect(t.type, TodoType.task);
      expect(t.sortOrder, 0);
    });

    test('Todo.create — parentId / type=note / sortOrder 전달 시 보존', () {
      final t = Todo.create(
        title: '메모',
        category: Category.idea,
        now: fixedNow,
        idGen: fixedId,
        parentId: 'parent-123',
        type: TodoType.note,
        sortOrder: 5,
      );
      expect(t.parentId, 'parent-123');
      expect(t.type, TodoType.note);
      expect(t.sortOrder, 5);
    });

    test('note 타입은 isDone 항상 false + toggleDone 무시', () {
      final note = Todo.create(
        title: '→ KV 캐싱 ...',
        category: Category.idea,
        now: fixedNow,
        idGen: fixedId,
        type: TodoType.note,
      );
      // doneAt 을 명시 set 해도 isDone false (note 는 체크 개념 X).
      final withDone = note.copyWith(doneAt: DateTime.utc(2026, 5, 28));
      expect(withDone.isDone, isFalse);

      // toggleDone 도 no-op.
      final toggled = note.toggleDone(now: () => DateTime.utc(2026, 5, 28));
      expect(toggled, note, reason: 'note 타입에 toggleDone 은 idempotent');
    });

    test('task 타입은 기존 toggleDone 동작 유지 (회귀 검증)', () {
      final t = Todo.create(
        title: 'x',
        category: Category.daily,
        now: () => DateTime.utc(2026, 5, 1),
        idGen: fixedId,
      );
      final later = DateTime.utc(2026, 5, 27);
      final toggled = t.toggleDone(now: () => later);
      expect(toggled.isDone, isTrue);
      expect(toggled.doneAt, later);
    });

    test('JSON round-trip — parentId/type/sortOrder 보존 (task)', () {
      final original = Todo(
        id: 'abc',
        title: 'PR 리뷰',
        category: Category.personalDev,
        dueAt: null,
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 27, 9),
        calendarEventId: null,
        parentId: 'parent-xyz',
        type: TodoType.task,
        sortOrder: 3,
      );
      final json = original.toJson();
      expect(json['parentId'], 'parent-xyz');
      expect(json['type'], 'task');
      expect(json['sortOrder'], 3);

      final restored = Todo.fromJson(json);
      expect(restored, original);
    });

    test('JSON round-trip — note 타입', () {
      final original = Todo(
        id: 'note-1',
        title: '→ 코기토 설계 메모',
        category: Category.work,
        dueAt: null,
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 27, 9),
        calendarEventId: null,
        parentId: 'project-cogito',
        type: TodoType.note,
        sortOrder: 0,
      );
      final json = original.toJson();
      expect(json['type'], 'note');
      final restored = Todo.fromJson(json);
      expect(restored, original);
    });

    test(
      'JSON 역호환 — 옛 v1.0 payload (parentId/type/sortOrder 누락) → 기본값으로 복원',
      () {
        // v1.0 시점의 Supabase row 가 신규 컬럼 없이 client 에 내려오는 케이스.
        final legacyJson = <String, dynamic>{
          'id': 'legacy',
          'title': '옛 todo',
          'category': 'work',
          'dueAt': null,
          'doneAt': null,
          'createdAt': '2026-05-01T09:00:00.000Z',
          'updatedAt': '2026-05-01T09:00:00.000Z',
          'calendarEventId': null,
        };
        final restored = Todo.fromJson(legacyJson);
        expect(restored.parentId, isNull);
        expect(restored.type, TodoType.task);
        expect(restored.sortOrder, 0);
      },
    );
  });

  group('google-calendar-sync — calendarId / calendarOrigin', () {
    test('Todo.create 기본값 — calendarId null, calendarOrigin app', () {
      final t = Todo.create(
        title: 'x',
        category: Category.daily,
        now: fixedNow,
        idGen: fixedId,
      );
      expect(t.calendarId, isNull);
      expect(t.calendarOrigin, 'app');
    });

    test('Todo.create — calendarId / calendarOrigin 전달 시 보존', () {
      final t = Todo.create(
        title: '구글에서 온 일정',
        category: Category.work,
        now: fixedNow,
        idGen: fixedId,
        calendarId: 'cal-xyz',
        calendarOrigin: 'gcal',
      );
      expect(t.calendarId, 'cal-xyz');
      expect(t.calendarOrigin, 'gcal');
    });

    test('JSON round-trip — calendarId / calendarOrigin 보존', () {
      final original = Todo(
        id: 'abc',
        title: 'PR 리뷰',
        category: Category.personalDev,
        dueAt: null,
        doneAt: null,
        createdAt: DateTime.utc(2026, 5, 27, 9),
        updatedAt: DateTime.utc(2026, 5, 27, 9),
        calendarEventId: 'evt-xyz',
        calendarId: 'cal-abc',
        calendarOrigin: 'gcal',
      );
      final json = original.toJson();
      expect(json['calendarId'], 'cal-abc');
      expect(json['calendarOrigin'], 'gcal');

      final restored = Todo.fromJson(json);
      expect(restored, original);
    });

    test('JSON 역호환 — calendarId/calendarOrigin 누락 → null / app 으로 안전 복원', () {
      // v1.x 시점 Supabase row 가 신규 컬럼 없이 client 에 내려오는 케이스.
      final legacyJson = <String, dynamic>{
        'id': 'legacy',
        'title': '옛 todo',
        'category': 'work',
        'dueAt': null,
        'doneAt': null,
        'createdAt': '2026-05-01T09:00:00.000Z',
        'updatedAt': '2026-05-01T09:00:00.000Z',
        'calendarEventId': null,
      };
      final restored = Todo.fromJson(legacyJson);
      expect(restored.calendarId, isNull);
      expect(restored.calendarOrigin, 'app');
    });
  });

  group('fast-tasks — endAt / isAllDay / timeAnchor', () {
    Todo base({
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

    test('dateMode 도출 — none/allDay/startTime/endTime/range', () {
      expect(base().dateMode, TodoDateMode.none);
      expect(
        base(dueAt: DateTime(2026, 5, 27), isAllDay: true).dateMode,
        TodoDateMode.allDay,
      );
      expect(
        base(dueAt: DateTime(2026, 5, 27, 9)).dateMode,
        TodoDateMode.startTime,
      );
      expect(
        base(dueAt: DateTime(2026, 5, 27, 9), timeAnchor: 'end').dateMode,
        TodoDateMode.endTime,
      );
      expect(
        base(
          dueAt: DateTime(2026, 5, 27),
          endAt: DateTime(2026, 5, 30),
        ).dateMode,
        TodoDateMode.range,
      );
    });

    test('JSON round-trip — 기간 + 하루종일', () {
      final original = base(
        dueAt: DateTime.utc(2026, 5, 27),
        endAt: DateTime.utc(2026, 5, 30),
        isAllDay: true,
      );
      expect(Todo.fromJson(original.toJson()), original);
    });

    test('JSON 역호환 — 신규 필드 누락 → 기본값 (isAllDay false, timeAnchor start)', () {
      final legacyJson = <String, dynamic>{
        'id': 'legacy',
        'title': '옛 todo',
        'category': 'work',
        'dueAt': null,
        'doneAt': null,
        'createdAt': '2026-05-01T09:00:00.000Z',
        'updatedAt': '2026-05-01T09:00:00.000Z',
        'calendarEventId': null,
      };
      final restored = Todo.fromJson(legacyJson);
      expect(restored.endAt, isNull);
      expect(restored.isAllDay, isFalse);
      expect(restored.timeAnchor, 'start');
    });
  });
}
