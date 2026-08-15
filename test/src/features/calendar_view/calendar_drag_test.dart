import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_drag.dart';
import 'package:solo_todo/src/features/calendar_view/calendar_entry.dart';

Todo make({
  String id = 'a',
  DateTime? dueAt,
  DateTime? endAt,
  bool isAllDay = false,
  String timeAnchor = 'start',
  int sortOrder = 7,
}) => Todo(
  id: id,
  title: 't',
  category: Category.work,
  dueAt: dueAt,
  endAt: endAt,
  isAllDay: isAllDay,
  timeAnchor: timeAnchor,
  sortOrder: sortOrder,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('applyDateDrop — 날짜 부분만 바꾼다', () {
    test('시각을 보존한 채 날짜만 이동', () {
      final t = make(dueAt: DateTime(2026, 8, 15, 14, 30));
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.dueAt, DateTime(2026, 8, 20, 14, 30));
    });

    test('초·밀리초까지 보존', () {
      final t = make(dueAt: DateTime(2026, 8, 15, 14, 30, 45, 123));
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.dueAt, DateTime(2026, 8, 20, 14, 30, 45, 123));
    });

    test('종일 항목은 종일인 채로 이동 (00:00 을 시각으로 승격시키지 않는다)', () {
      final t = make(dueAt: DateTime(2026, 8, 15), isAllDay: true);
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.dueAt, DateTime(2026, 8, 20));
      expect(moved.isAllDay, isTrue);
      expect(moved.dateMode, TodoDateMode.allDay);
    });

    test('timeAnchor(마감 기준)도 보존', () {
      final t = make(dueAt: DateTime(2026, 8, 15, 18), timeAnchor: 'end');
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.timeAnchor, 'end');
      expect(moved.dateMode, TodoDateMode.endTime);
    });

    test('과거로도 이동한다', () {
      final t = make(dueAt: DateTime(2026, 8, 15, 9));
      final moved = applyDateDrop(t, DateTime(2026, 8, 3));
      expect(moved.dueAt, DateTime(2026, 8, 3, 9));
    });

    test('월·연 경계를 넘어 이동', () {
      final t = make(dueAt: DateTime(2026, 12, 31, 23, 59));
      final moved = applyDateDrop(t, DateTime(2027, 1, 2));
      expect(moved.dueAt, DateTime(2027, 1, 2, 23, 59));
    });
  });

  group('applyDateDrop — 기간 항목은 길이를 유지한 채 평행이동', () {
    test('3일짜리 기간이 그대로 3일', () {
      final t = make(
        dueAt: DateTime(2026, 8, 15, 9),
        endAt: DateTime(2026, 8, 18, 18),
      );
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.dueAt, DateTime(2026, 8, 20, 9));
      expect(moved.endAt, DateTime(2026, 8, 23, 18));
      expect(moved.dateMode, TodoDateMode.range);
    });

    test('뒤로 옮겨도 길이 유지', () {
      final t = make(
        dueAt: DateTime(2026, 8, 15),
        endAt: DateTime(2026, 8, 17),
        isAllDay: true,
      );
      final moved = applyDateDrop(t, DateTime(2026, 8, 10));
      expect(moved.dueAt, DateTime(2026, 8, 10));
      expect(moved.endAt, DateTime(2026, 8, 12));
    });

    test('월을 넘는 기간도 길이 유지', () {
      final t = make(
        dueAt: DateTime(2026, 8, 30),
        endAt: DateTime(2026, 9, 2),
        isAllDay: true,
      );
      final moved = applyDateDrop(t, DateTime(2026, 10, 1));
      expect(moved.dueAt, DateTime(2026, 10, 1));
      expect(moved.endAt, DateTime(2026, 10, 4));
    });
  });

  group('applyDateDrop — 무날짜 항목에 날짜 부여', () {
    test('시각을 모르므로 종일 단일 항목이 된다', () {
      final t = make(dueAt: null);
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.dueAt, DateTime(2026, 8, 20));
      expect(moved.isAllDay, isTrue);
      expect(moved.endAt, isNull);
      expect(moved.dateMode, TodoDateMode.allDay);
    });

    test('드롭 날짜의 시각 성분은 무시하고 자정 기준으로 붙인다', () {
      final t = make(dueAt: null);
      final moved = applyDateDrop(t, DateTime(2026, 8, 20, 17, 42));
      expect(moved.dueAt, DateTime(2026, 8, 20));
    });
  });

  group('applyDateDrop — 순서와 무변경', () {
    test('sortOrder 는 절대 건드리지 않는다 (날짜 이동은 순서 조작이 아니다)', () {
      final t = make(dueAt: DateTime(2026, 8, 15, 9), sortOrder: 42);
      expect(applyDateDrop(t, DateTime(2026, 8, 20)).sortOrder, 42);
      expect(
        applyDateDrop(
          make(dueAt: null, sortOrder: 42),
          DateTime(2026, 8, 20),
        ).sortOrder,
        42,
      );
    });

    test('같은 날에 떨어뜨리면 원본 그대로 반환 (저장 경로가 헛돌지 않도록)', () {
      final t = make(dueAt: DateTime(2026, 8, 15, 14, 30));
      expect(identical(applyDateDrop(t, DateTime(2026, 8, 15)), t), isTrue);
      // 같은 날의 다른 시각으로 떨어뜨려도 날짜가 같으면 무변경.
      expect(identical(applyDateDrop(t, DateTime(2026, 8, 15, 23)), t), isTrue);
    });

    test('UTC 로 저장된 값은 UTC 로 돌려준다 (다시 읽을 때 하루 밀림 방지)', () {
      final t = make(dueAt: DateTime.utc(2026, 8, 15, 5));
      final moved = applyDateDrop(t, DateTime(2026, 8, 20));
      expect(moved.dueAt!.isUtc, isTrue);
      // local 로 환산했을 때 날짜가 목표일이어야 한다.
      expect(dateOnly(moved.dueAt!.toLocal()), DateTime(2026, 8, 20));
    });
  });

  group('isMeaningfulDrop', () {
    test('원래 날짜면 false, 다른 날짜면 true', () {
      final e = TodoEntry(make(dueAt: DateTime(2026, 8, 15, 9)));
      expect(isMeaningfulDrop(e, DateTime(2026, 8, 15)), isFalse);
      expect(isMeaningfulDrop(e, DateTime(2026, 8, 16)), isTrue);
    });

    test('기간 항목은 시작일 기준으로 판단', () {
      final e = TodoEntry(
        make(dueAt: DateTime(2026, 8, 15), endAt: DateTime(2026, 8, 18)),
      );
      expect(isMeaningfulDrop(e, DateTime(2026, 8, 15)), isFalse);
      // 기간에 속한 날이라도 시작일이 아니면 실제 이동이다.
      expect(isMeaningfulDrop(e, DateTime(2026, 8, 17)), isTrue);
    });
  });
}
