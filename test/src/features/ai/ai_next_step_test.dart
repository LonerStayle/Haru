import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/next_step/ai_next_step.dart';

import 'fake_ai_gateway.dart';

void main() {
  Todo t({
    Category category = Category.idea,
    String? description,
    DateTime? done,
    String? seriesId,
  }) => Todo(
    id: 'a',
    title: '사이드 프로젝트 앱',
    category: category,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    description: description,
    doneAt: done,
    seriesId: seriesId,
  );

  group('parseNextSteps', () {
    test('제목·시간·이유를 읽고 시간은 5~30 으로 맞춘다', () {
      final out = parseNextSteps({
        'steps': [
          {'title': '- 경쟁 앱 3개 스크린샷 모으기', 'minutes': 20, 'why': '방향 잡기'},
          {'title': '첫 화면 스케치하기', 'minutes': 90, 'why': '바로 만들기'},
          {'title': '이름 후보 정하기', 'minutes': 1, 'why': ''},
        ],
      }, parentTitle: '사이드 프로젝트 앱');
      expect(out, const [
        AiNextStep(title: '경쟁 앱 3개 스크린샷 모으기', minutes: 20, why: '방향 잡기'),
        AiNextStep(title: '첫 화면 스케치하기', minutes: 30, why: '바로 만들기'),
        AiNextStep(title: '이름 후보 정하기', minutes: 5),
      ]);
    });

    test('부모와 같은 제목·중복 제목·모양이 틀린 원소는 버린다', () {
      final out = parseNextSteps({
        'steps': [
          {'title': '사이드  프로젝트 앱', 'minutes': 10, 'why': 'x'},
          {'title': '자료 모으기', 'minutes': 10, 'why': 'x'},
          {'title': '자료 모으기 ', 'minutes': 15, 'why': 'y'},
          {'title': '', 'minutes': 10, 'why': 'x'},
          {'title': '시간 없음', 'why': 'x'},
          'not an object',
          {'title': '문자 시간', 'minutes': '12', 'why': 'z'},
        ],
      }, parentTitle: '사이드 프로젝트 앱');
      expect(out!.map((s) => s.title), ['자료 모으기', '문자 시간']);
      expect(out.last.minutes, 12);
    });

    test('최대 3개', () {
      final out = parseNextSteps({
        'steps': [
          for (var i = 0; i < 5; i++)
            {'title': '행동 $i', 'minutes': 10, 'why': 'w'},
        ],
      }, parentTitle: 'p');
      expect(out!.map((s) => s.title), ['행동 0', '행동 1', '행동 2']);
    });

    test('steps 가 배열이 아니면 null, 쓸 만한 게 없으면 빈 목록', () {
      expect(parseNextSteps({'steps': 'x'}, parentTitle: 'p'), isNull);
      expect(parseNextSteps({}, parentTitle: 'p'), isNull);
      expect(
        parseNextSteps({
          'steps': [
            {'title': 'p', 'minutes': 10, 'why': 'w'},
          ],
        }, parentTitle: 'p'),
        isEmpty,
      );
    });
  });

  test('applies — 장기 목표·아이디어의 미완료, 반복 아님', () {
    expect(AiNextStepService.applies(t()), isTrue);
    expect(AiNextStepService.applies(t(category: Category.longterm)), isTrue);
    expect(AiNextStepService.applies(t(category: Category.work)), isFalse);
    expect(AiNextStepService.applies(t(done: DateTime(2026))), isFalse);
    expect(AiNextStepService.applies(t(seriesId: 's')), isFalse);
  });

  test('입력 — 제목·카테고리 이름·경로·설명 앞 300자', () {
    final input =
        jsonDecode(
              AiNextStepService.buildInput(
                t(description: '가' * 400),
                path: ['상위'],
              ),
            )
            as Map<String, dynamic>;
    expect(input['title'], '사이드 프로젝트 앱');
    expect(input['category'], Category.idea.label);
    expect(input['path'], ['상위']);
    expect((input['description'] as String).length, 300);

    final bare =
        jsonDecode(AiNextStepService.buildInput(t())) as Map<String, dynamic>;
    expect(bare['description'], isNull);
    expect(bare['path'], isEmpty);
  });

  test('suggest — 게이트웨이 응답을 해석, 실패는 null', () async {
    final ai = FakeAiGateway()
      ..jsonQueue.add({
        'steps': [
          {'title': '자료 모으기', 'minutes': 10, 'why': 'w'},
        ],
      });
    const service = AiNextStepService();
    final out = await service.suggest(ai, t(), path: ['상위']);
    expect(out!.single.title, '자료 모으기');
    expect(ai.calls.single.schema, AiNextStepService.schema);
    expect(ai.calls.single.input, contains('상위'));

    expect(await service.suggest(ai, t()), isNull);
  });
}
