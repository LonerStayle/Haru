import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/ai/backlog/ai_stale_advisor.dart';

import 'fake_ai_gateway.dart';

void main() {
  final now = DateTime(2026, 10, 10, 9);
  const nToId = {1: 'a', 2: 'b', 3: 'c'};

  Todo make(String id, {Category category = Category.work}) => Todo(
    id: id,
    title: '제목-$id',
    category: category,
    createdAt: DateTime(2026, 8, 1),
    updatedAt: DateTime(2026, 8, 1),
    description: '설명-$id',
  );

  group('parseStaleSuggestions', () {
    test('보낸 n 만, 같은 n 은 첫 답만, 목록 밖 action 은 버린다', () {
      final out = parseStaleSuggestions({
        'suggestions': [
          {'n': 1, 'action': 'done', 'reason': ' 배포 완료라고 적힘 '},
          {'n': 1, 'action': 'keep', 'reason': '두 번째'},
          {'n': 9, 'action': 'done', 'reason': '없는 번호'},
          {'n': 2, 'action': 'delete', 'reason': '삭제는 없음'},
          {'n': '3', 'action': 'nextMonth', 'reason': '미뤄도 됨'},
          'x',
        ],
      }, nToId)!;
      expect(out, {
        'a': const AiStaleSuggestion(AiStaleAction.done, '배포 완료라고 적힘'),
        'c': const AiStaleSuggestion(AiStaleAction.nextMonth, '미뤄도 됨'),
      });
    });

    test('reason 은 40자에서 자르고, 없으면 빈 문자열', () {
      final out = parseStaleSuggestions({
        'suggestions': [
          {'n': 1, 'action': 'keep', 'reason': '가' * 60},
          {'n': 2, 'action': 'nextWeek'},
        ],
      }, nToId)!;
      expect(out['a']!.reason.length, 40);
      expect(out['b']!.reason, '');
    });

    test('longterm 강등 대상이면 keep 으로', () {
      final out = parseStaleSuggestions(
        {
          'suggestions': [
            {'n': 1, 'action': 'longterm', 'reason': '학습'},
            {'n': 2, 'action': 'longterm', 'reason': '큰 개선'},
          ],
        },
        nToId,
        demoteLongterm: (id) => id == 'a',
      )!;
      expect(out['a']!.action, AiStaleAction.keep);
      expect(out['b']!.action, AiStaleAction.longterm);
    });

    test('최상위가 틀리면 null', () {
      expect(parseStaleSuggestions({'suggestions': 'x'}, nToId), isNull);
      expect(parseStaleSuggestions({}, nToId), isNull);
    });
  });

  group('AiStaleAdvisor.suggest', () {
    test('40건씩 나눠 순서대로 보내고, 실패한 묶음은 null', () async {
      final gw = FakeAiGateway()
        ..jsonQueue.addAll([
          {
            'suggestions': [
              {'n': 1, 'action': 'done', 'reason': '끝남'},
            ],
          },
          null,
          {
            'suggestions': [
              {'n': 1, 'action': 'nextWeek', 'reason': '곧'},
            ],
          },
        ]);
      final items = [for (var i = 0; i < 85; i++) make('t$i')];
      final results = await const AiStaleAdvisor()
          .suggest(gw, items, now: now, sendDescription: true)
          .toList();
      expect(gw.calls, hasLength(3));
      final sizes = [
        for (final c in gw.calls) (jsonDecode(c.input)['items'] as List).length,
      ];
      expect(sizes, [40, 40, 5]);
      expect(results, [
        {'t0': const AiStaleSuggestion(AiStaleAction.done, '끝남')},
        null,
        {'t80': const AiStaleSuggestion(AiStaleAction.nextWeek, '곧')},
      ]);
    });

    test('보내는 입력 — today·age·kids, 설명 토글 off 면 desc 없음', () async {
      final gw = FakeAiGateway();
      await const AiStaleAdvisor()
          .suggest(
            gw,
            [make('a')],
            now: now,
            sendDescription: false,
            childCounts: {'a': 2},
          )
          .toList();
      final input = jsonDecode(gw.calls.single.input) as Map<String, dynamic>;
      expect(input['today'], '2026-10-10(토)');
      final item = (input['items'] as List).single as Map<String, dynamic>;
      expect(item['n'], 1);
      expect(item['age'], 70);
      expect(item['kids'], 2);
      expect(item.containsKey('desc'), isFalse);
      expect(gw.calls.single.input, isNot(contains('"a"')), reason: 'id 대신 n');
    });

    test('장기 목표 카테고리가 없거나 이미 장기 목표면 longterm → keep', () async {
      Map<String, dynamic> answer() => {
        'suggestions': [
          {'n': 1, 'action': 'longterm', 'reason': '학습'},
          {'n': 2, 'action': 'longterm', 'reason': '학습'},
        ],
      };
      final items = [make('a'), make('b', category: Category.longterm)];
      final gw = FakeAiGateway()..jsonQueue.addAll([answer(), answer()]);

      final normal = await const AiStaleAdvisor()
          .suggest(gw, items, now: now, sendDescription: true)
          .single;
      expect(normal!['a']!.action, AiStaleAction.longterm);
      expect(normal['b']!.action, AiStaleAction.keep);

      final missing = await const AiStaleAdvisor()
          .suggest(
            gw,
            items,
            now: now,
            sendDescription: true,
            longtermAvailable: false,
          )
          .single;
      expect(missing!['a']!.action, AiStaleAction.keep);
    });
  });
}
