import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/policies/monthly_repeat_policy.dart';
import 'package:solo_todo/src/domain/todo.dart';

void main() {
  Todo t(
    String id,
    String title,
    DateTime created, {
    Category category = Category.daily,
    DateTime? due,
    String? series,
    bool master = false,
    String? parent,
  }) => Todo(
    id: id,
    title: title,
    category: category,
    createdAt: created,
    updatedAt: created,
    dueAt: due,
    seriesId: series,
    isSeriesMaster: master,
    parentId: parent,
  );

  test('baseTitle / keyOf — 월·연·날짜 표시를 빼고 띄어쓰기 차이는 무시', () {
    expect(MonthlyRepeatPolicy.baseTitle('아파트 관리비 9월분 입금'), '아파트 관리비 입금');
    expect(MonthlyRepeatPolicy.baseTitle('2026년 10월 청년전월세 제출'), '청년전월세 제출');
    expect(MonthlyRepeatPolicy.baseTitle('카드값 9/23 확인'), '카드값 확인');
    expect(
      MonthlyRepeatPolicy.keyOf('아파트관리비 5월분 입금'),
      MonthlyRepeatPolicy.keyOf('아파트 관리비 7월분 입금'),
    );
  });

  test('서로 다른 3개월 이상이면 묶음 전체에 같은 제안', () {
    final all = [
      t('a', '아파트관리비 5월분 입금', DateTime(2026, 5, 31)),
      t('b', '아파트관리비 6월분 입금', DateTime(2026, 6, 26)),
      t('c', '아파트 관리비 7월분 입금', DateTime(2026, 8, 9)),
      t('d', '아파트 관리비 9월분 입금', DateTime(2026, 9, 23)),
    ];
    final r = MonthlyRepeatPolicy.detect(all);
    expect(r.keys, containsAll(['a', 'b', 'c', 'd']));
    expect(r['a']!.title, '아파트 관리비 입금');
    expect(r['a']!.monthCount, 4);
    expect(r['a']!.dayOfMonth, 23, reason: '가장 최근 항목의 날짜(날짜 없으면 만든 날)');
  });

  test('2개월뿐이면, 또는 제목에 월 표시가 없으면 제안하지 않는다', () {
    final two = [
      t('a', '전월세 8월 제출', DateTime(2026, 8, 9)),
      t('b', '전월세 9월 제출', DateTime(2026, 9, 23)),
      t('c', '전월세 9월 제출', DateTime(2026, 9, 24)),
    ];
    expect(MonthlyRepeatPolicy.detect(two), isEmpty);
    final noMonth = [
      t('a', '장보기', DateTime(2026, 5, 1)),
      t('b', '장보기', DateTime(2026, 6, 1)),
      t('c', '장보기', DateTime(2026, 7, 1)),
    ];
    expect(MonthlyRepeatPolicy.detect(noMonth), isEmpty);
  });

  test('카테고리가 다르면 다른 묶음, 반복 마스터가 있으면 제안 안 함, 하위는 제외', () {
    final base = [
      t('a', '보고 5월', DateTime(2026, 5, 1)),
      t('b', '보고 6월', DateTime(2026, 6, 1), category: Category.work),
      t('c', '보고 7월', DateTime(2026, 7, 1)),
      t('k', '보고 8월', DateTime(2026, 8, 1), parent: 'a'),
    ];
    expect(MonthlyRepeatPolicy.detect(base), isEmpty);

    final withMaster = [
      t('a', '관리비 5월분', DateTime(2026, 5, 1)),
      t('b', '관리비 6월분', DateTime(2026, 6, 1)),
      t('c', '관리비 7월분', DateTime(2026, 7, 1)),
      t('m', '관리비', DateTime(2026, 8, 1), master: true, series: 'm'),
    ];
    expect(MonthlyRepeatPolicy.detect(withMaster), isEmpty);
  });

  test('nextDate — 오늘 포함 다음 그 날, 없는 날은 말일', () {
    final now = DateTime(2026, 9, 25, 10);
    expect(MonthlyRepeatPolicy.nextDate(25, now), DateTime(2026, 9, 25));
    expect(MonthlyRepeatPolicy.nextDate(23, now), DateTime(2026, 10, 23));
    expect(MonthlyRepeatPolicy.nextDate(31, now), DateTime(2026, 9, 30));
    expect(
      MonthlyRepeatPolicy.nextDate(31, DateTime(2026, 1, 31, 12)),
      DateTime(2026, 1, 31),
    );
    expect(
      MonthlyRepeatPolicy.nextDate(30, DateTime(2026, 12, 31)),
      DateTime(2027, 1, 30),
    );
  });

  test('firstDate — 마지막 항목이 이미 앞날짜에 잡혀 있으면 그다음 달부터', () {
    final now = DateTime(2026, 9, 25, 10);
    MonthlyRepeatSuggestion s(DateTime latest) => MonthlyRepeatSuggestion(
      key: 'k',
      title: 't',
      monthCount: 3,
      dayOfMonth: latest.day,
      latestDate: latest,
    );
    // "9월분" 을 10/21 로 잡아 둠 → 10/21 은 이미 있으니 11/21.
    expect(
      MonthlyRepeatPolicy.firstDate(s(DateTime(2026, 10, 21)), now),
      DateTime(2026, 11, 21),
    );
    // 지난 항목(9/21) → 오늘 이후 첫 21일 = 10/21.
    expect(
      MonthlyRepeatPolicy.firstDate(s(DateTime(2026, 9, 21)), now),
      DateTime(2026, 10, 21),
    );
    // 오늘 날짜의 항목이 이미 있으면 다음 달.
    expect(
      MonthlyRepeatPolicy.firstDate(s(DateTime(2026, 9, 25)), now),
      DateTime(2026, 10, 25),
    );
  });

  test('detect 는 가장 최근 항목의 날짜(dueAt 우선)를 기억한다', () {
    final all = [
      t('a', '관리비 7월분', DateTime(2026, 7, 20)),
      t('b', '관리비 8월분', DateTime(2026, 8, 20)),
      t('c', '관리비 9월분', DateTime(2026, 9, 23), due: DateTime(2026, 10, 21, 9)),
    ];
    final r = MonthlyRepeatPolicy.detect(all)['a']!;
    expect(r.dayOfMonth, 21);
    expect(r.latestDate, DateTime(2026, 10, 21));
  });

  test('오탐 회귀 — 월간·월요일·N년 기간은 월/연 표시가 아니다', () {
    expect(MonthlyRepeatPolicy.baseTitle('TOP 10 월간 지표'), 'TOP 10 월간 지표');
    expect(MonthlyRepeatPolicy.baseTitle('3 월요일 회의'), '3 월요일 회의');
    expect(MonthlyRepeatPolicy.baseTitle('10년 만기 적금'), '10년 만기 적금');
    expect(MonthlyRepeatPolicy.baseTitle('2026년도 계획'), '2026년도 계획');
    expect(MonthlyRepeatPolicy.baseTitle('카드값 9월 결제'), '카드값 결제');
    final monthly = [
      t('a', '월간 보고 5월', DateTime(2026, 5, 1)),
      t('b', '월간 보고 6월', DateTime(2026, 6, 1)),
      t('c', '월간 보고 7월', DateTime(2026, 7, 1)),
    ];
    expect(MonthlyRepeatPolicy.detect(monthly)['a']!.title, '월간 보고');
  });
}
