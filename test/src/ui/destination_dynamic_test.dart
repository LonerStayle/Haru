import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/ui/destination.dart';

/// v1.5 — AppDestination.buildAll 동적 단축키 매핑 검증.
///
/// 순서·단축키: today=0 / outline=1 / timeline=2 / categories 3~9 (앞 7개) /
/// 8번째부터 단축키 없음.
void main() {
  group('AppDestination.buildAll', () {
    test('빈 categories — today + outline + calendar (0/1/2)', () {
      final dests = AppDestination.buildAll(const []);
      expect(dests.length, 3);
      expect(dests[0].isToday, isTrue);
      expect(dests[0].shortcutDigit, 0);
      expect(dests[1].isOutline, isTrue);
      expect(dests[1].shortcutDigit, 1);
      expect(dests[2].isCalendar, isTrue);
      expect(dests[2].shortcutDigit, 2);
    });

    test('builtin 5종 — today=0 / outline=1 / calendar=2 / 카테고리 3~7', () {
      final dests = AppDestination.buildAll(Category.builtinSeeds);
      expect(dests.length, 8);
      expect(dests[0].isToday, isTrue);
      expect(dests[0].shortcutDigit, 0);
      expect(dests[1].isOutline, isTrue);
      expect(dests[1].shortcutDigit, 1);
      expect(dests[2].isCalendar, isTrue);
      expect(dests[2].shortcutDigit, 2);
      for (var i = 0; i < 5; i++) {
        expect(dests[i + 3].shortcutDigit, i + 3);
        expect(dests[i + 3].category, Category.builtinSeeds[i]);
      }
    });

    test('7 카테고리 — 카테고리 3~9 (앞 7개 모두 단축키)', () {
      final seven = [
        for (var i = 0; i < 7; i++)
          Category(
            id: 'c$i',
            label: 'C$i',
            iconCodePoint: 0xe865,
            colorValue: 0xFF000000,
            sortOrder: i,
            isBuiltin: false,
          ),
      ];
      final dests = AppDestination.buildAll(seven);
      expect(dests.length, 10);
      expect(dests[0].shortcutDigit, 0); // today
      expect(dests[1].shortcutDigit, 1); // outline
      expect(dests[2].shortcutDigit, 2); // timeline
      for (var i = 0; i < 7; i++) {
        expect(dests[i + 3].shortcutDigit, i + 3); // 3~9
      }
    });

    test('8 카테고리 — 앞 7개만 3~9, 8번째는 단축키 없음 (-1)', () {
      final eight = [
        for (var i = 0; i < 8; i++)
          Category(
            id: 'c$i',
            label: 'C$i',
            iconCodePoint: 0xe865,
            colorValue: 0xFF000000,
            sortOrder: i,
            isBuiltin: false,
          ),
      ];
      final dests = AppDestination.buildAll(eight);
      expect(dests.length, 11);
      expect(dests[2].shortcutDigit, 2); // timeline
      // 앞 7개 카테고리 — 3~9
      for (var i = 0; i < 7; i++) {
        expect(dests[i + 3].shortcutDigit, i + 3);
      }
      // 8번째 카테고리 — 단축키 없음.
      expect(dests.last.shortcutDigit, -1);
    });

    test('12 카테고리 — 앞 7개만 단축키 3~9 / 나머지 -1', () {
      final twelve = [
        for (var i = 0; i < 12; i++)
          Category(
            id: 'c$i',
            label: 'C$i',
            iconCodePoint: 0xe865,
            colorValue: 0xFF000000,
            sortOrder: i,
            isBuiltin: false,
          ),
      ];
      final dests = AppDestination.buildAll(twelve);
      expect(dests.length, 15); // today + outline + timeline + 12 cat
      expect(dests[2].shortcutDigit, 2); // timeline
      // 앞 7개 카테고리 — 단축키 3~9
      for (var i = 0; i < 7; i++) {
        expect(dests[i + 3].shortcutDigit, i + 3);
      }
      // 8~12번째 카테고리 — 단축키 없음
      for (var i = 7; i < 12; i++) {
        expect(dests[i + 3].shortcutDigit, -1);
      }
    });

    test('tooltipWithShortcut — 단축키 있으면 (n), 없으면 라벨만', () {
      final dests = AppDestination.buildAll([
        Category(
          id: 'c',
          label: '커스텀',
          iconCodePoint: 0xe865,
          colorValue: 0xFF000000,
          sortOrder: 0,
          isBuiltin: false,
        ),
      ]);
      // today, outline, calendar, 커스텀(digit 3).
      expect(dests[1].tooltipWithShortcut, '전체보기 (1)');
      expect(dests[2].tooltipWithShortcut, '캘린더 (2)');
      expect(dests[3].tooltipWithShortcut, '커스텀 (3)');

      // 8개 이상 카테고리에선 후순위 destination 의 tooltip 은 라벨만.
      final many = [
        for (var i = 0; i < 11; i++)
          Category(
            id: 'c$i',
            label: 'C$i',
            iconCodePoint: 0xe865,
            colorValue: 0xFF000000,
            sortOrder: i,
            isBuiltin: false,
          ),
      ];
      final manyDests = AppDestination.buildAll(many);
      // index 3..9 (앞 7개) 단축키 있음, index 10 (8번째 카테고리) 부터 없음.
      expect(manyDests[10].tooltipWithShortcut, 'C7'); // 8번째 카테고리 — 단축키 없음
      expect(manyDests.last.tooltipWithShortcut, 'C10'); // 마지막 카테고리 — 단축키 없음
    });
  });
}
