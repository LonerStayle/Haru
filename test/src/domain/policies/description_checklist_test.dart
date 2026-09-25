import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/policies/description_checklist.dart';

void main() {
  group('DescriptionChecklist.parse', () {
    test('목록 줄은 하위 후보로, 문단은 설명에 남긴다', () {
      final r = DescriptionChecklist.parse(
        '팀원 PR 2건 확인.\n\n- 에러 코드 매핑\n- 재시도 로직 테스트\n\n마감 금요일',
      );
      expect(r.items, const [
        ChecklistItem('에러 코드 매핑'),
        ChecklistItem('재시도 로직 테스트'),
      ]);
      expect(r.remaining, '팀원 PR 2건 확인.\n\n마감 금요일');
    });

    test('번호·별표·가운뎃점·들여쓴 하위 목록을 모두 펼친다', () {
      final r = DescriptionChecklist.parse(
        '1. 첫째\n2) 둘째\n* 셋째\n• 넷째\n  - 넷째의 하위\n· 다섯째',
      );
      expect(r.items.map((i) => i.title), [
        '첫째',
        '둘째',
        '셋째',
        '넷째',
        '넷째의 하위',
        '다섯째',
      ]);
      expect(r.remaining, isNull);
    });

    test('체크박스는 완료 여부를 가져온다', () {
      final r = DescriptionChecklist.parse('- [ ] 할 것\n- [x] 끝낸 것\n[X] 대문자');
      expect(r.items, const [
        ChecklistItem('할 것'),
        ChecklistItem('끝낸 것', done: true),
        ChecklistItem('대문자', done: true),
      ]);
    });

    test('마크다운 강조 기호를 벗긴다', () {
      final r = DescriptionChecklist.parse('- **백로그** 정리\n- `bm25` 비율');
      expect(r.items.map((i) => i.title), ['백로그 정리', 'bm25 비율']);
    });

    test('목록이 없으면 비어 있고 설명은 그대로', () {
      final r = DescriptionChecklist.parse('그냥 메모\n두 번째 줄');
      expect(r.isEmpty, isTrue);
      expect(r.remaining, '그냥 메모\n두 번째 줄');
      expect(DescriptionChecklist.parse(null).isEmpty, isTrue);
      expect(DescriptionChecklist.parse('  ').isEmpty, isTrue);
    });

    test('하이픈으로 시작해도 공백이 없으면 목록이 아니다 (-1, --옵션)', () {
      final r = DescriptionChecklist.parse('-1 은 음수\n--force 금지');
      expect(r.isEmpty, isTrue);
    });

    test('기호만 있고 내용이 빈 줄은 버린다', () {
      final r = DescriptionChecklist.parse('- 하나\n- [ ] \n-  ');
      expect(r.items, const [ChecklistItem('하나')]);
    });
  });

  test('stripListLine — 붙여넣은 줄의 기호 정리', () {
    expect(DescriptionChecklist.stripListLine('- **백로그**'), '백로그');
    expect(DescriptionChecklist.stripListLine('3. 배포'), '배포');
    expect(DescriptionChecklist.stripListLine('- [x] 끝'), '끝');
    expect(DescriptionChecklist.stripListLine('평범한 줄'), '평범한 줄');
    expect(DescriptionChecklist.stripListLine('2026년 계획'), '2026년 계획');
  });

  test('오탐 회귀 — __init__ 은 그대로, 구분선은 항목이 아니다', () {
    expect(
      DescriptionChecklist.stripListLine('- __init__.py 정리'),
      '__init__.py 정리',
    );
    final r = DescriptionChecklist.parse('- 하나\n* * *\n- 둘');
    expect(r.items.map((i) => i.title), ['하나', '둘']);
  });
}
