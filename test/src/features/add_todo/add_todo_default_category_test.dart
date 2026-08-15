import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/group.dart';
import 'package:solo_todo/src/features/add_todo/add_todo_default_category.dart';
import 'package:solo_todo/src/ui/destination.dart';

/// `_openAddTodo` 기본 카테고리 결정 규칙 — "보고 있는 화면 기준" 검증.
///
/// 과거 버그: raw `_index` 만 봐서 (a) 그룹 화면을 무시하고 (b) 비동기 리로드로
/// index 가 어긋나면 오늘로 폴백 → 보던 카테고리와 다른 값이 기본 선택됨.
void main() {
  // sortOrder 순으로 groupId 를 부여한 카테고리 목록 (buildAll 입력과 동일 형태).
  final work = Category.work.copyWith(groupId: 'g1'); // g1 첫 카테고리
  final dev = Category.personalDev.copyWith(groupId: 'g1'); // g1 둘째
  final daily = Category.daily.copyWith(groupId: 'g2'); // g2 첫 카테고리
  final idea = Category.idea; // 미분류
  final categories = [work, dev, daily, idea];

  final groups = [
    const Group(id: 'g1', label: '회사', colorValue: 0xFF000000, sortOrder: 0),
    const Group(id: 'g2', label: '개인', colorValue: 0xFF111111, sortOrder: 1),
  ];

  final destinations = AppDestination.buildAll(categories);
  // buildAll 순서: [오늘, 전체보기, 캘린더, work, dev, daily, idea].
  final workIndex = destinations.indexWhere((d) => d.category?.id == work.id);
  final ideaIndex = destinations.indexWhere((d) => d.category?.id == idea.id);
  final todayIndex = destinations.indexWhere((d) => d.isToday);

  Category resolve({
    required int index,
    String? selectedGroupId,
    List<Category>? cats,
    List<AppDestination>? dests,
  }) => resolveAddTodoDefaultCategory(
    categories: cats ?? categories,
    groups: groups,
    destinations: dests ?? destinations,
    index: index,
    selectedGroupId: selectedGroupId,
  );

  group('그룹 화면', () {
    test('그룹을 보는 중이면 그 그룹의 첫 카테고리를 기본값으로 (index 무관)', () {
      // 오늘(index=0)에 머물러 있어도 그룹이 선택돼 있으면 그룹의 첫 카테고리.
      expect(resolve(index: todayIndex, selectedGroupId: 'g1'), work);
      expect(resolve(index: todayIndex, selectedGroupId: 'g2'), daily);
    });

    test('다른 카테고리 index 에 있어도 그룹 화면이 우선', () {
      // idea(미분류) destination 에 index 가 있어도 그룹 g1 선택 중이면 work.
      expect(resolve(index: ideaIndex, selectedGroupId: 'g1'), work);
    });

    test('이미 삭제된 그룹 id 면 그룹 화면으로 보지 않고 destination 규칙으로', () {
      // 존재하지 않는 그룹 → onGroup false → index(오늘) → 목록 첫 항목 fallback.
      expect(resolve(index: todayIndex, selectedGroupId: 'no-such'), work);
    });

    test('그룹에 카테고리가 하나도 없으면 fallback(목록 첫 항목)', () {
      final emptyGroup = [
        const Group(id: 'g9', label: '빈그룹', colorValue: 0xFF222222),
      ];
      final r = resolveAddTodoDefaultCategory(
        categories: categories,
        groups: emptyGroup,
        destinations: destinations,
        index: todayIndex,
        selectedGroupId: 'g9',
      );
      expect(r, work); // categories.first
    });
  });

  group('카테고리/전역 화면', () {
    test('카테고리 화면이면 그 카테고리', () {
      expect(resolve(index: workIndex), work);
      expect(resolve(index: ideaIndex), idea);
    });

    test('오늘/전체보기 등 카테고리 없는 화면이면 목록 첫 항목', () {
      expect(resolve(index: todayIndex), work); // categories.first = work
    });

    test('index 가 destinations 범위를 벗어나면 오늘로 클램프 → 목록 첫 항목', () {
      // 비동기 카테고리 리로드로 index 가 길이를 초과한 상황 재현.
      expect(resolve(index: 999), work);
      expect(resolve(index: -1), work);
    });
  });

  group('빈 목록 fallback', () {
    test('categories 가 비면 builtinSeeds.first 로 fallback', () {
      final r = resolveAddTodoDefaultCategory(
        categories: const [],
        groups: const [],
        destinations: AppDestination.buildAll(const []),
        index: 0,
        selectedGroupId: null,
      );
      expect(r, Category.builtinSeeds.first);
    });
  });
}
