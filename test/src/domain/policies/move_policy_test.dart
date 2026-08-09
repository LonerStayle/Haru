import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/move_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  final created = DateTime.utc(2026, 8, 9, 9, 0);

  Todo node(String id, {String? parentId, Category? category}) => Todo(
    id: id,
    title: id,
    category: category ?? Category.work,
    dueAt: null,
    doneAt: null,
    createdAt: created,
    updatedAt: created,
    calendarEventId: null,
    parentId: parentId,
  );

  // 회사: a > b > c,  d (독립 root)
  final a = node('a');
  final b = node('b', parentId: 'a');
  final c = node('c', parentId: 'b');
  final d = node('d');
  final all = [a, b, c, d];

  group('descendants', () {
    test('재귀적으로 모든 자손을 모은다 (자기 자신 제외)', () {
      expect(MovePolicy.descendants('a', all).map((t) => t.id), ['b', 'c']);
      expect(MovePolicy.descendants('b', all).map((t) => t.id), ['c']);
      expect(MovePolicy.descendants('c', all), isEmpty);
    });

    test('데이터가 사이클이어도 무한 루프에 빠지지 않는다', () {
      // x → y → x 로 서로를 부모로 가리키는 손상 데이터.
      final x = node('x', parentId: 'y');
      final y = node('y', parentId: 'x');
      expect(MovePolicy.descendants('x', [x, y]).map((t) => t.id), ['y']);
    });
  });

  group('canMove', () {
    test('최상위로(null) 이동은 항상 허용', () {
      expect(
        MovePolicy.canMove(item: c, newParentId: null, all: all),
        isTrue,
        reason: '하위 → 상위',
      );
    });

    test('다른 트리의 항목 밑으로 이동 허용', () {
      expect(
        MovePolicy.canMove(item: c, newParentId: 'd', all: all),
        isTrue,
        reason: '하위 → 다른 항목의 하위',
      );
      expect(
        MovePolicy.canMove(item: d, newParentId: 'b', all: all),
        isTrue,
        reason: '상위 → 다른 항목의 하위',
      );
    });

    test('자기 자신을 부모로 지정하면 거부', () {
      expect(MovePolicy.canMove(item: a, newParentId: 'a', all: all), isFalse);
    });

    test('자기 자손을 부모로 지정하면 거부 (서브트리가 트리에서 떨어져 나감)', () {
      expect(
        MovePolicy.canMove(item: a, newParentId: 'b', all: all),
        isFalse,
        reason: '직속 자식',
      );
      expect(
        MovePolicy.canMove(item: a, newParentId: 'c', all: all),
        isFalse,
        reason: '손자',
      );
    });
  });

  group('isNoop', () {
    test('부모·카테고리 둘 다 그대로면 no-op', () {
      expect(
        MovePolicy.isNoop(item: b, newParentId: 'a', newCategoryId: 'work'),
        isTrue,
      );
    });

    test('부모가 달라지면 no-op 아님', () {
      expect(
        MovePolicy.isNoop(item: b, newParentId: 'd', newCategoryId: 'work'),
        isFalse,
      );
    });

    test('카테고리가 달라지면 no-op 아님', () {
      expect(
        MovePolicy.isNoop(item: b, newParentId: 'a', newCategoryId: 'daily'),
        isFalse,
      );
    });
  });
}
