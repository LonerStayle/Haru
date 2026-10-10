import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/checklist/ai_checklist.dart';

void main() {
  const original =
      '이번 주 안에 처리해야 함. 먼저 로그를 모으고, 그 다음 원인을 정리해서 공유한다. 끝나면 회고 문서에 남긴다. 배경 설명이 좀 더 길게 붙어 있다.';

  test('항목을 목록으로, intro 는 위에', () {
    final out = buildChecklistDescription({
      'intro': '이번 주 안에 처리해야 함.',
      'items': ['- 로그 모으기', '원인 정리해서 공유', '원인 정리해서 공유', '회고 문서에 남기기'],
    }, original: original);
    expect(
      out,
      '이번 주 안에 처리해야 함.\n\n- [ ] 로그 모으기\n- [ ] 원인 정리해서 공유\n- [ ] 회고 문서에 남기기',
    );
  });

  test('항목이 2개 미만이면 null', () {
    expect(
      buildChecklistDescription({
        'intro': null,
        'items': ['하나'],
      }, original: original),
      isNull,
    );
    expect(
      buildChecklistDescription({'items': 'x'}, original: original),
      isNull,
    );
  });

  test('원문보다 지나치게 길면(지어낸 항목) null', () {
    expect(
      buildChecklistDescription({
        'intro': null,
        'items': List.generate(12, (i) => '지어낸 아주 긴 단계 번호 $i 를 수행하기'),
      }, original: '짧은 설명이다'),
      isNull,
    );
  });

  test('applies — 80자 이상·목록 아님·미완료 할 일만', () {
    Todo t({String? d, DateTime? done, TodoType type = TodoType.task}) => Todo(
      id: 'a',
      title: 'a',
      category: Category.work,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      description: d,
      doneAt: done,
      type: type,
    );
    expect(AiChecklistService.applies(t(d: original)), isTrue);
    expect(AiChecklistService.applies(t(d: '짧다')), isFalse);
    expect(AiChecklistService.applies(t(d: '$original\n- 하나\n- 둘')), isFalse);
    expect(
      AiChecklistService.applies(t(d: original, done: DateTime(2026))),
      isFalse,
    );
    expect(
      AiChecklistService.applies(t(d: original, type: TodoType.note)),
      isFalse,
    );
  });
}
