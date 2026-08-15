import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../domain/category.dart';

/// destination 의 종류 — UI 라우팅 분기에 사용.
///
/// v1.6 — `timeline` 을 `calendar` 로 **교체**했다. 캘린더 화면이 타임라인을 흡수하고
/// (달력 격자 + 선택일 목록), 기존 버킷 목록은 캘린더 안의 `[목록]` 세그먼트로 살아 있다.
/// 새 destination 을 추가하지 않고 교체한 이유는 모바일 `NavigationBar` 가 4슬롯 고정이라
/// 하나만 늘어도 라벨이 압축되기 때문 — 교체는 자리 문제도 기능 손실도 없다.
enum DestinationKind { today, category, outline, calendar }

/// 사이드바 / 바텀 네비의 단일 navigation 단위.
///
/// 순서 (v1.6 — 타임라인 자리를 캘린더가 이어받음):
/// - `today` (kind=today) 가 항상 첫 번째 — 단축키 0.
/// - `outline` (kind=outline) 이 두 번째 — 단축키 1. ('오늘' 다음으로 자주 본다)
/// - `calendar` (kind=calendar) 가 세 번째 — 단축키 2. (월 달력 + 선택일 목록)
/// - 그 다음 categories (DB row 순서 = sortOrder asc) — 단축키 3~9 (앞 7개만).
///
/// v1.0~v1.1 의 `AppDestination.all` (static) 은 v1.2 부터 [buildAll] 로 동적 생성.
/// 호환을 위해 `all` 도 [Category.builtinSeeds] 기준으로 노출 (테스트 / 옛 호출처용).
class AppDestination {
  const AppDestination._({
    required this.kind,
    required this.label,
    required this.icon,
    required this.color,
    required this.shortcutDigit,
    this.category,
  });

  final DestinationKind kind;
  final String label;
  final IconData icon;
  final Color color;

  /// `0` = Today, `1` = Outline, `2` = Calendar, `3~9` = categories (앞 7개).
  /// 음수 = 단축키 없음 (카테고리가 9개 이상일 때 후순위 destination 들).
  final int shortcutDigit;

  /// kind == category 일 때만 non-null. 그 외엔 null.
  final Category? category;

  bool get isToday => kind == DestinationKind.today;
  bool get isOutline => kind == DestinationKind.outline;
  bool get isCalendar => kind == DestinationKind.calendar;

  /// 단축키가 있으면 "회사 할일 (1)", 없으면 그냥 "회사 할일".
  String get tooltipWithShortcut =>
      shortcutDigit < 0 ? label : '$label ($shortcutDigit)';

  /// v1.5 — categories 를 받아 동적 destination 리스트 생성.
  ///
  /// 순서·단축키: today (digit 0) → outline (digit 1) → calendar (digit 2) →
  /// categories (digit 3~9, 앞 7개). 8번째 이후 카테고리는 단축키 없음
  /// (sidebar / NavigationBar tap 으로만 접근).
  static List<AppDestination> buildAll(List<Category> categories) {
    final dests = <AppDestination>[
      const AppDestination._(
        kind: DestinationKind.today,
        label: '오늘',
        icon: Icons.today_outlined,
        color: AppPalette.accent,
        shortcutDigit: 0,
      ),
      // v1.4 — 전체보기를 '오늘' 바로 다음으로. 단축키 1.
      const AppDestination._(
        kind: DestinationKind.outline,
        label: '전체보기',
        icon: Icons.account_tree_outlined,
        color: AppPalette.accent,
        shortcutDigit: 1,
      ),
      // v1.6 — 월 달력 + 선택일 목록. 단축키 2 (v1.5 타임라인 자리를 그대로 이어받는다).
      const AppDestination._(
        kind: DestinationKind.calendar,
        label: '캘린더',
        icon: Icons.calendar_month_outlined,
        color: AppPalette.accent,
        shortcutDigit: 2,
      ),
    ];

    for (var i = 0; i < categories.length; i++) {
      final c = categories[i];
      // 앞 7개만 단축키 3~9 부여 — 8번째 이후는 단축키 없음.
      final digit = i < 7 ? i + 3 : -1;
      dests.add(
        AppDestination._(
          kind: DestinationKind.category,
          label: c.label,
          icon: c.icon,
          color: c.color,
          category: c,
          shortcutDigit: digit,
        ),
      );
    }

    return dests;
  }

  /// builtin 5종 기준의 default destination 리스트 — 옛 호출처 / 테스트 호환.
  /// v1.2 production 코드는 [buildAll] + `categoriesProvider` 를 사용해야 동적.
  static final List<AppDestination> all = buildAll(Category.builtinSeeds);
}
