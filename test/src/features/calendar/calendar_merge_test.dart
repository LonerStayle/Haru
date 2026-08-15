import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar/calendar_merge.dart';
import 'package:solo_todo/src/features/calendar/calendar_service.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 9);

  Todo todo({
    String title = '제목',
    DateTime? dueAt,
    DateTime? endAt,
    bool isAllDay = false,
    String timeAnchor = 'start',
    DateTime? updatedAt,
    Category? category,
    String? parentId,
    int sortOrder = 3,
    String? description,
    DateTime? doneAt,
  }) => Todo(
    id: 'todo-1',
    title: title,
    category: category ?? Category.work,
    dueAt: dueAt ?? DateTime.utc(2026, 8, 20, 14),
    endAt: endAt,
    doneAt: doneAt,
    isAllDay: isAllDay,
    timeAnchor: timeAnchor,
    createdAt: t0,
    updatedAt: updatedAt ?? t0,
    calendarEventId: 'ev-1',
    calendarId: 'write@cal',
    parentId: parentId,
    sortOrder: sortOrder,
    description: description,
  );

  /// 앱이 방금 push 한 상태 그대로의 이벤트 (서명 rev == todo.updatedAt).
  gcal.Event pushedEvent(Todo t, {DateTime? serverUpdated}) {
    // ignore: invalid_use_of_visible_for_testing_member
    final e = CalendarService.buildEvent(t);
    e.id = 'ev-1';
    e.updated = serverUpdated ?? t.updatedAt.add(const Duration(seconds: 1));
    return e;
  }

  group('echo 차단 — 우리가 쓴 변경은 되돌아와도 무시한다', () {
    test('서명 rev 가 로컬 updatedAt 과 같으면 skip', () {
      final local = todo();
      final result = mergeEventIntoTodo(
        event: pushedEvent(local),
        local: local,
      );
      expect(result.kind, MergeKind.echo);
      expect(result.merged, isNull);
    });

    test('이벤트가 서버 시각상 더 최신이어도 echo 면 무시한다', () {
      // 구글이 스탬프한 updated 는 우리가 push 한 직후라 항상 로컬보다 나중이다.
      // 시각만 비교하면 우리가 쓴 변경이 매번 되돌아와 무한 루프가 된다.
      final local = todo();
      final e = pushedEvent(
        local,
        serverUpdated: local.updatedAt.add(const Duration(hours: 1)),
      );
      expect(mergeEventIntoTodo(event: e, local: local).kind, MergeKind.echo);
    });

    test('로컬이 그 뒤로 또 바뀌었으면 echo 가 아니다', () {
      final pushed = todo();
      final e = pushedEvent(pushed);
      // push 후 사용자가 앱에서 또 고쳤다 — rev 가 어긋난다.
      final local = pushed.copyWith(
        title: '앱에서 또 고침',
        updatedAt: t0.add(const Duration(minutes: 5)),
      );
      expect(
        mergeEventIntoTodo(event: e, local: local).kind,
        isNot(MergeKind.echo),
      );
    });
  });

  group('LWW — 나중에 바뀐 쪽이 이긴다', () {
    test('캘린더가 더 최신이면 앱을 갱신한다', () {
      final local = todo(title: '옛 제목');
      final e = pushedEvent(local)
        ..summary = '캘린더에서 고친 제목'
        ..extendedProperties = gcal.EventExtendedProperties(
          private: {'haruTodoId': 'todo-1', 'haruRev': '옛-rev'},
        )
        ..updated = local.updatedAt.add(const Duration(minutes: 10));

      final r = mergeEventIntoTodo(event: e, local: local);
      expect(r.kind, MergeKind.updated);
      expect(r.merged!.title, '캘린더에서 고친 제목');
    });

    test('앱이 더 최신이면 무시한다', () {
      final local = todo(updatedAt: t0.add(const Duration(hours: 2)));
      final e = pushedEvent(local)
        ..summary = '캘린더 쪽 옛 제목'
        ..extendedProperties = gcal.EventExtendedProperties(
          private: {'haruTodoId': 'todo-1', 'haruRev': '옛-rev'},
        )
        ..updated = t0.add(const Duration(minutes: 1));

      expect(
        mergeEventIntoTodo(event: e, local: local).kind,
        MergeKind.localWins,
      );
    });

    test('동률이면 앱이 이긴다', () {
      final local = todo();
      final e = pushedEvent(local)
        ..summary = '동시 수정'
        ..extendedProperties = gcal.EventExtendedProperties(
          private: {'haruTodoId': 'todo-1', 'haruRev': '옛-rev'},
        )
        ..updated = local.updatedAt;

      expect(
        mergeEventIntoTodo(event: e, local: local).kind,
        MergeKind.localWins,
      );
    });
  });

  group('병합 범위 — 날짜와 제목만 덮는다', () {
    Todo mergedOf(gcal.Event e, Todo local) =>
        mergeEventIntoTodo(event: e, local: local).merged!;

    gcal.Event calendarEdit(Todo local, void Function(gcal.Event) edit) {
      final e = pushedEvent(local)
        ..extendedProperties = gcal.EventExtendedProperties(
          private: {'haruTodoId': 'todo-1', 'haruRev': '옛-rev'},
        )
        ..updated = local.updatedAt.add(const Duration(minutes: 10));
      edit(e);
      return e;
    }

    test('카테고리·부모·정렬·메모는 보존된다', () {
      final local = todo(
        category: Category.daily,
        parentId: 'parent-1',
        sortOrder: 7,
        description: '내 메모',
      );
      final m = mergedOf(calendarEdit(local, (e) => e.summary = '새 제목'), local);
      expect(m.title, '새 제목');
      expect(m.category.id, Category.daily.id);
      expect(m.parentId, 'parent-1');
      expect(m.sortOrder, 7);
      expect(m.description, '내 메모');
    });

    test('완료 상태는 캘린더가 건드리지 않는다', () {
      final done = DateTime.utc(2026, 8, 19, 10);
      final local = todo(doneAt: done);
      final m = mergedOf(calendarEdit(local, (e) => e.summary = '새 제목'), local);
      expect(m.doneAt, done);
    });

    test('시간을 옮기면 dueAt 이 따라간다', () {
      final local = todo();
      final m = mergedOf(
        calendarEdit(local, (e) {
          e.start = gcal.EventDateTime(
            dateTime: DateTime.utc(2026, 8, 21, 16),
            timeZone: 'UTC',
          );
          e.end = gcal.EventDateTime(
            dateTime: DateTime.utc(2026, 8, 21, 17),
            timeZone: 'UTC',
          );
        }),
        local,
      );
      expect(m.dueAt!.toUtc(), DateTime.utc(2026, 8, 21, 16));
    });

    test('updatedAt 은 이벤트의 서버 시각으로 올라간다 — 재푸시 루프 방지', () {
      final local = todo();
      final e = calendarEdit(local, (x) => x.summary = '새 제목');
      final m = mergedOf(e, local);
      expect(m.updatedAt, e.updated);
    });

    test('링크 정보는 유지된다', () {
      final local = todo();
      final m = mergedOf(calendarEdit(local, (e) => e.summary = '새 제목'), local);
      expect(m.calendarEventId, 'ev-1');
      expect(m.calendarId, 'write@cal');
    });
  });

  group('매핑 불가', () {
    test('시작 시각이 없는 이벤트는 병합하지 않는다', () {
      final local = todo();
      final e = gcal.Event(id: 'ev-1', summary: 'x')
        ..updated = local.updatedAt.add(const Duration(minutes: 10));
      expect(
        mergeEventIntoTodo(event: e, local: local).kind,
        MergeKind.unmappable,
      );
    });

    test('서버 수정 시각이 없으면 비교할 수 없어 무시한다', () {
      final local = todo();
      final e = pushedEvent(local)
        ..extendedProperties = gcal.EventExtendedProperties(
          private: {'haruTodoId': 'todo-1', 'haruRev': '옛-rev'},
        )
        ..updated = null;
      expect(
        mergeEventIntoTodo(event: e, local: local).kind,
        MergeKind.localWins,
      );
    });
  });
}
