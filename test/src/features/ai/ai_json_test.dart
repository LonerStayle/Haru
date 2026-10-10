import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/ai_json.dart';

void main() {
  final today = DateTime(2026, 10, 10, 9);

  group('date', () {
    test('종일 — 로컬 자정', () {
      expect(
        AiJson.date('2026-10-15', null, today: today),
        AiDate(DateTime(2026, 10, 15), allDay: true),
      );
    });

    test('시각이 있으면 로컬 시각', () {
      expect(
        AiJson.date('2026-10-15', '14:30', today: today),
        AiDate(DateTime(2026, 10, 15, 14, 30), allDay: false),
      );
    });

    test('없는 날짜(2/30)는 정규화하지 않고 버린다', () {
      expect(AiJson.date('2027-02-30', null, today: today), isNull);
    });

    test('범위 밖·형식 틀림은 버린다', () {
      expect(AiJson.date('2026-09-01', null, today: today), isNull);
      expect(AiJson.date('2028-01-01', null, today: today), isNull);
      expect(AiJson.date('2026/10/15', null, today: today), isNull);
      expect(AiJson.date(null, '10:00', today: today), isNull);
    });

    test('틀린 시각은 시각만 버리고 종일로', () {
      expect(
        AiJson.date('2026-10-15', '25:00', today: today),
        AiDate(DateTime(2026, 10, 15), allDay: true),
      );
    });
  });

  test('localDate — UTC 로 저장된 종일 항목도 로컬 날짜로', () {
    final utcMidnightKst = DateTime(2026, 10, 15).toUtc();
    expect(AiJson.localDate(utcMidnightKst, allDay: true), '2026-10-15');
    expect(
      AiJson.localDate(DateTime(2026, 10, 15, 9, 5), allDay: false),
      '2026-10-15 09:05',
    );
  });

  test('today — 요일 포함', () {
    expect(AiJson.today(today), '2026-10-10(토)');
  });

  test('title — 기호 제거·한 줄·길이 컷', () {
    expect(AiJson.title('- [ ] **보고서** 쓰기'), '보고서 쓰기');
    expect(AiJson.title('줄\n바꿈'), '줄 바꿈');
    expect(AiJson.title('   '), isNull);
    expect(AiJson.title(3), isNull);
    expect(AiJson.title('가' * 200)!.length, 120);
  });

  test('appearsIn — 공백·줄바꿈 무시', () {
    const src = '다음 주 금요일까지\n  보고서 제출';
    expect(AiJson.appearsIn('금요일까지 보고서', src), isTrue);
    expect(AiJson.appearsIn('월요일', src), isFalse);
    expect(AiJson.appearsIn('', src), isFalse);
    expect(AiJson.appearsIn(null, src), isFalse);
  });

  test('objects·integer', () {
    expect(
      AiJson.objects([
        1,
        {'a': 1},
        'x',
      ]),
      [
        {'a': 1},
      ],
    );
    expect(AiJson.objects('x'), isEmpty);
    expect(AiJson.integer(3.0), 3);
    expect(AiJson.integer('4'), 4);
    expect(AiJson.integer(3.5), isNull);
  });
}
