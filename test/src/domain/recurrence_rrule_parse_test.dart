import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/recurrence.dart';

void main() {
  group('tryFromRRule — toRRule 왕복', () {
    const rules = [
      RecurrenceRule(freq: RecurrenceFreq.daily),
      RecurrenceRule(freq: RecurrenceFreq.daily, interval: 3),
      RecurrenceRule(freq: RecurrenceFreq.weekly),
      RecurrenceRule(
        freq: RecurrenceFreq.weekly,
        interval: 2,
        byWeekday: {1, 3},
      ),
      RecurrenceRule(freq: RecurrenceFreq.monthly),
      RecurrenceRule(freq: RecurrenceFreq.monthly, interval: 2),
      RecurrenceRule(freq: RecurrenceFreq.yearly),
    ];

    for (final rule in rules) {
      test('UNTIL 없음 — ${rule.encode()}', () {
        final parsed = RecurrenceRule.tryFromRRule(rule.toRRule(null));
        expect(parsed, isNotNull);
        expect(parsed!.rule, rule);
        expect(parsed.until, isNull);
      });
    }

    test('UNTIL 포함 — 규칙과 종료 시각이 모두 복원된다', () {
      const rule = RecurrenceRule(freq: RecurrenceFreq.weekly, byWeekday: {5});
      final until = DateTime.utc(2026, 12, 31, 15, 30, 45);
      final parsed = RecurrenceRule.tryFromRRule(rule.toRRule(until));
      expect(parsed!.rule, rule);
      expect(parsed.until, until);
    });

    test('local UNTIL 도 UTC 로 왕복된다', () {
      const rule = RecurrenceRule(freq: RecurrenceFreq.daily);
      final until = DateTime(2026, 12, 31, 9);
      final parsed = RecurrenceRule.tryFromRRule(rule.toRRule(until));
      expect(parsed!.until, until.toUtc());
    });
  });

  group('tryFromRRule — 구글이 보내는 형태', () {
    test('RRULE: prefix 없이도 파싱된다', () {
      final parsed = RecurrenceRule.tryFromRRule('FREQ=DAILY;INTERVAL=2');
      expect(parsed!.rule.freq, RecurrenceFreq.daily);
      expect(parsed.rule.interval, 2);
    });

    test('INTERVAL 생략 시 1', () {
      final parsed = RecurrenceRule.tryFromRRule('RRULE:FREQ=MONTHLY');
      expect(parsed!.rule.interval, 1);
    });

    test('소문자·공백도 허용', () {
      final parsed = RecurrenceRule.tryFromRRule(
        'rrule:freq=weekly; byday=mo,fr',
      );
      expect(parsed!.rule.freq, RecurrenceFreq.weekly);
      expect(parsed.rule.byWeekday, {1, 5});
    });

    test('UNTIL 이 날짜만(시각 없음)이어도 파싱된다', () {
      final parsed = RecurrenceRule.tryFromRRule('FREQ=DAILY;UNTIL=20261231');
      expect(parsed!.until, DateTime.utc(2026, 12, 31));
    });
  });

  group('tryFromRRule — 미지원은 null (단일 할 일로 폴백)', () {
    test('BYSETPOS (매월 첫째 주 월요일 류)', () {
      expect(
        RecurrenceRule.tryFromRRule('FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1'),
        isNull,
      );
    });

    test('BYMONTHDAY', () {
      expect(RecurrenceRule.tryFromRRule('FREQ=MONTHLY;BYMONTHDAY=15'), isNull);
    });

    test('COUNT — 회수 종료는 우리 모델에 없다', () {
      expect(RecurrenceRule.tryFromRRule('FREQ=DAILY;COUNT=10'), isNull);
    });

    test('BYDAY 의 서수 접두사 (2MO = 둘째 주 월요일)', () {
      expect(RecurrenceRule.tryFromRRule('FREQ=MONTHLY;BYDAY=2MO'), isNull);
    });

    test('FREQ=HOURLY 등 지원 밖 주기', () {
      expect(RecurrenceRule.tryFromRRule('FREQ=HOURLY;INTERVAL=6'), isNull);
    });
  });

  group('tryFromRRule — 깨진 입력도 예외 없이 null', () {
    test('빈 문자열', () {
      expect(RecurrenceRule.tryFromRRule(''), isNull);
    });

    test('FREQ 없음', () {
      expect(RecurrenceRule.tryFromRRule('INTERVAL=2;BYDAY=MO'), isNull);
    });

    test('아무 문자열', () {
      expect(RecurrenceRule.tryFromRRule('이건 규칙이 아니다'), isNull);
    });

    test('UNTIL 이 파싱 불가여도 규칙은 살리고 until 만 버린다', () {
      final parsed = RecurrenceRule.tryFromRRule('FREQ=DAILY;UNTIL=nonsense');
      expect(parsed, isNotNull);
      expect(parsed!.rule.freq, RecurrenceFreq.daily);
      expect(parsed.until, isNull);
    });
  });
}
