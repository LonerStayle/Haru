import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/stale_backlog_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  final now = DateTime(2026, 9, 25, 10);
  Todo t(
    String id, {
    int ageDays = 40,
    Category category = Category.work,
    TodoType type = TodoType.task,
    DateTime? done,
    DateTime? due,
    String? parent,
    String? series,
    bool master = false,
  }) {
    final created = now.subtract(Duration(days: ageDays));
    return Todo(
      id: id,
      title: id,
      category: category,
      type: type,
      createdAt: created,
      updatedAt: created,
      doneAt: done,
      dueAt: due,
      parentId: parent,
      seriesId: series,
      isSeriesMaster: master,
    );
  }

  List<String> ids(List<Todo> all, {Set<String>? active}) => [
    for (final x in StaleBacklogPolicy.select(
      all,
      activeCategoryIds: active ?? {Category.work.id, Category.daily.id},
      now: now,
    ))
      x.id,
  ];

  test('30일 넘은 미완료 최상위 할 일만, 오래된 순', () {
    final all = [
      t('b', ageDays: 45),
      t('a', ageDays: 90),
      t('fresh', ageDays: 10),
      t('edge', ageDays: 30),
    ];
    expect(ids(all), ['a', 'b', 'edge']);
  });

  test('완료·메모·하위·반복·보관 카테고리는 뺀다', () {
    final all = [
      t('keep'),
      t('done', done: now),
      t('note', type: TodoType.note),
      t('child', parent: 'keep'),
      t('master', master: true, series: 's'),
      t('instance', series: 's'),
      t('archived', category: Category.idea),
    ];
    expect(ids(all), ['keep']);
  });

  test('오늘 이후 날짜가 잡힌 건 계획된 일이라 빼고, 지난 날짜는 남긴다', () {
    final all = [
      t('future', due: DateTime(2026, 9, 30)),
      t('today', due: DateTime(2026, 9, 25)),
      t('past', due: DateTime(2026, 9, 1)),
    ];
    expect(ids(all), ['past']);
  });

  test('ageInDays', () {
    expect(StaleBacklogPolicy.ageInDays(t('x', ageDays: 45), now), 45);
  });
}
