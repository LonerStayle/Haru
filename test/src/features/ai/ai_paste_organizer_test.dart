import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/ai_json.dart';
import 'package:solo_todo/src/features/ai/paste/ai_paste_organizer.dart';

void main() {
  final today = DateTime(2026, 10, 10, 9);
  const raw = '회의록\n- 다음 주 금요일까지 보고서 제출\n- 디자인 시안 검토\n  - 색상\n  - 폰트\n감사합니다';

  Map<String, dynamic> item(
    String title, {
    String? categoryId,
    String? date,
    String? time,
    String timeAnchor = 'start',
    String? dateEvidence,
    String? evidence,
    List<Map<String, dynamic>> children = const [],
  }) => {
    'title': title,
    'categoryId': categoryId,
    'date': date,
    'time': time,
    'timeAnchor': timeAnchor,
    'dateEvidence': dateEvidence,
    'evidence': evidence,
    'children': children,
  };

  List<AiPasteDraft> parse(List<Map<String, dynamic>> items) =>
      parsePasteDrafts(
        {'items': items},
        raw: raw,
        categoryIds: {'work', 'daily'},
        today: today,
      )!;

  test('원문 근거가 있는 날짜만, 마감이면 end', () {
    final d = parse([
      item(
        '보고서 제출',
        categoryId: 'work',
        date: '2026-10-16',
        time: '18:00',
        timeAnchor: 'end',
        dateEvidence: '다음 주 금요일까지',
        evidence: '다음 주 금요일까지 보고서 제출',
      ),
    ]).single;
    expect(d.categoryId, 'work');
    expect(d.date, AiDate(DateTime(2026, 10, 16, 18), allDay: false));
    expect(d.timeAnchor, 'end');
    expect(d.evidence, '다음 주 금요일까지 보고서 제출');
  });

  test('근거가 원문에 없으면 날짜를 버린다 · 없는 날짜도 버린다', () {
    final d = parse([
      item('지어낸 날짜', date: '2026-10-12', dateEvidence: '월요일'),
      item('없는 날', date: '2027-02-30', dateEvidence: '다음 주 금요일까지'),
    ]);
    expect(d[0].date, isNull);
    expect(d[1].date, isNull);
    expect(d.every((x) => x.timeAnchor == 'start'), isTrue);
  });

  test('모르는 카테고리는 null(시트 기본), 원문에 없는 근거는 숨김', () {
    final d = parse([
      item('디자인 시안 검토', categoryId: 'ghost', evidence: '없는 문장'),
    ]).single;
    expect(d.categoryId, isNull);
    expect(d.evidence, isNull);
  });

  test('하위 1단계, 제목 없는 항목은 건너뜀', () {
    final d = parse([
      item(
        '디자인 시안 검토',
        children: [
          {'title': '색상', 'evidence': null},
          {'title': '  ', 'evidence': null},
          {'title': '폰트', 'evidence': null, 'children': []},
        ],
      ),
      item('  '),
    ]);
    expect(d, hasLength(1));
    expect(d.single.children.map((c) => c.title), ['색상', '폰트']);
  });

  test('items 가 없으면 null, 빈 배열이면 빈 목록', () {
    expect(
      parsePasteDrafts({'x': 1}, raw: raw, categoryIds: const {}, today: today),
      isNull,
    );
    expect(parse(const []), isEmpty);
  });
}
