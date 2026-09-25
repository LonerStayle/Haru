import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/ui_prefs.dart';

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

  group('마지막에 쓴 카테고리 (2026-09-25)', () {
    test('오늘/전체보기에서는 마지막에 쓴 카테고리가 기본값', () {
      final r = resolveAddTodoDefaultCategory(
        categories: categories,
        groups: groups,
        destinations: destinations,
        index: todayIndex,
        selectedGroupId: null,
        lastUsedId: daily.id,
      );
      expect(r, daily);
    });

    test('카테고리 화면이면 마지막에 쓴 것보다 보고 있는 카테고리가 우선', () {
      final r = resolveAddTodoDefaultCategory(
        categories: categories,
        groups: groups,
        destinations: destinations,
        index: workIndex,
        selectedGroupId: null,
        lastUsedId: daily.id,
      );
      expect(r, work);
    });

    test('그룹 화면: 마지막에 쓴 카테고리가 그 그룹 안이면 그것, 아니면 그룹 첫 카테고리', () {
      Category inGroup(String g, String last) => resolveAddTodoDefaultCategory(
        categories: categories,
        groups: groups,
        destinations: destinations,
        index: todayIndex,
        selectedGroupId: g,
        lastUsedId: last,
      );
      expect(inGroup('g1', dev.id), dev);
      expect(inGroup('g2', dev.id), daily);
    });

    test('마지막에 쓴 카테고리가 보관·삭제돼 목록에 없으면 사이드바 첫 카테고리', () {
      final r = resolveAddTodoDefaultCategory(
        categories: categories,
        groups: groups,
        destinations: destinations,
        index: todayIndex,
        selectedGroupId: null,
        lastUsedId: 'archived-or-deleted',
      );
      expect(r, work);
    });
  });

  group('사이드바 표시 순서', () {
    // 실제 버그 재현: 카테고리 sortOrder 최소(JS슈퍼=4)가 두 번째 그룹에 있고,
    // 첫 그룹의 카테고리(Bxg=101)는 sortOrder 가 더 크다 → 예전엔 JS슈퍼가 기본값이었다.
    const bxg = Category(
      id: 'bxg',
      label: 'Bxg',
      iconCodePoint: 0xe000,
      colorValue: 0xFF000000,
      sortOrder: 101,
      groupId: 'company',
    );
    const jsSuper = Category(
      id: 'js',
      label: 'JS슈퍼',
      iconCodePoint: 0xe000,
      colorValue: 0xFF000000,
      sortOrder: 4,
      groupId: 'project',
    );
    const loose = Category(
      id: 'loose',
      label: '미분류',
      iconCodePoint: 0xe000,
      colorValue: 0xFF000000,
      sortOrder: 0,
    );
    const orderGroups = [
      Group(id: 'project', label: '프로젝트', colorValue: 0, sortOrder: 1),
      Group(id: 'company', label: '회사', colorValue: 0, sortOrder: 0),
    ];

    test('그룹 순서 → 카테고리 순서, 그룹 없는 카테고리는 맨 아래', () {
      expect(
        categoriesInSidebarOrder(const [loose, jsSuper, bxg], orderGroups),
        [bxg, jsSuper, loose],
      );
    });

    test('기억된 값이 없으면 오늘 화면 ⌘N 기본값 = 사이드바 첫 카테고리', () {
      const cats = [loose, jsSuper, bxg];
      final dests = AppDestination.buildAll(cats);
      final r = resolveAddTodoDefaultCategory(
        categories: cats,
        groups: orderGroups,
        destinations: dests,
        index: dests.indexWhere((d) => d.isToday),
        selectedGroupId: null,
      );
      expect(r, bxg);
    });
  });

  group('LastUsedCategoryNotifier', () {
    test('기록하면 저장되고, 앱을 다시 켜면 복원된다', () async {
      final store = MemoryUiPrefsStore();
      final c1 = ProviderContainer(
        overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
      );
      c1.read(lastUsedCategoryProvider);
      await c1.read(lastUsedCategoryProvider.notifier).restored;
      await c1.read(lastUsedCategoryProvider.notifier).record('bxg');
      expect(c1.read(lastUsedCategoryProvider), 'bxg');
      c1.dispose();

      final c2 = ProviderContainer(
        overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c2.dispose);
      c2.read(lastUsedCategoryProvider);
      await c2.read(lastUsedCategoryProvider.notifier).restored;
      expect(c2.read(lastUsedCategoryProvider), 'bxg');
    });

    test('복원 전에 기록한 값이 저장값보다 이긴다', () async {
      final store = MemoryUiPrefsStore()
        ..data[LastUsedCategoryNotifier.key] = {'old'};
      final c = ProviderContainer(
        overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(lastUsedCategoryProvider.notifier);
      await n.record('new');
      await n.restored;
      expect(c.read(lastUsedCategoryProvider), 'new');
      expect(store.data[LastUsedCategoryNotifier.key], {'new'});
    });
  });

  group('설정의 기본 카테고리 × 마지막에 쓴 카테고리 (Phase 4 머지)', () {
    Category r({String? preferred, String? last, String? group}) =>
        resolveAddTodoDefaultCategory(
          categories: categories,
          groups: groups,
          destinations: destinations,
          index: todayIndex,
          selectedGroupId: group,
          preferredCategoryId: preferred,
          lastUsedId: last,
        );

    test('설정에서 고정했으면 그것이 먼저, "자동"(null)이면 마지막에 쓴 것', () {
      expect(r(preferred: idea.id, last: daily.id), idea);
      expect(r(last: daily.id), daily);
      expect(r(), work, reason: '둘 다 없으면 사이드바 첫 카테고리');
    });

    test('그룹 화면: 그룹 안에 있는 쪽만 — 고정값 → 마지막 → 그룹 첫', () {
      expect(r(preferred: dev.id, last: work.id, group: 'g1'), dev);
      expect(r(preferred: idea.id, last: dev.id, group: 'g1'), dev);
      expect(r(preferred: idea.id, last: daily.id, group: 'g1'), work);
    });
  });
}
