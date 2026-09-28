import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'destination.dart';

/// 메인 영역에 떠 있는 화면 종류.
///
/// [categories] 는 모바일 하단 네비 4번째 칸의 "카테고리 목록" 화면이다(데스크탑은
/// 사이드바가 그 역할을 하므로 쓰지 않는다).
enum ShellPage { today, outline, calendar, categories, category }

/// 셸의 현재 위치 — 화면 종류 + (카테고리 화면이면) 카테고리 id.
///
/// 예전엔 `_AppShellState._index`(destinations 배열 인덱스)였다. 카테고리가 추가·삭제
/// 되면 인덱스가 옆 카테고리를 가리키는 문제가 있었고, 셸 밖(전체보기의 카테고리 헤더
/// 등)에서 화면을 바꿀 길이 없었다. id 로 기억하면 둘 다 해결된다.
@immutable
class ShellLocation {
  const ShellLocation._(this.page, [this.categoryId]);

  const ShellLocation.category(String id) : this._(ShellPage.category, id);

  static const today = ShellLocation._(ShellPage.today);
  static const outline = ShellLocation._(ShellPage.outline);
  static const calendar = ShellLocation._(ShellPage.calendar);
  static const categories = ShellLocation._(ShellPage.categories);

  final ShellPage page;
  final String? categoryId;

  /// destination → 위치.
  factory ShellLocation.of(AppDestination d) => switch (d.kind) {
    DestinationKind.today => today,
    DestinationKind.outline => outline,
    DestinationKind.calendar => calendar,
    DestinationKind.category => ShellLocation.category(d.category!.id),
  };

  /// 이 위치가 [d] 를 가리키는지.
  bool matches(AppDestination d) => this == ShellLocation.of(d);

  @override
  bool operator ==(Object other) =>
      other is ShellLocation &&
      other.page == page &&
      other.categoryId == categoryId;

  @override
  int get hashCode => Object.hash(page, categoryId);

  @override
  String toString() =>
      'ShellLocation(${page.name}${categoryId == null ? '' : ':$categoryId'})';
}

class ShellLocationNotifier extends Notifier<ShellLocation> {
  /// 카테고리 화면에서 뒤로 갈 곳 — 전체보기의 카테고리 머리로 들어왔으면 전체보기.
  /// null 이면 카테고리 목록(모바일) / 없음(데스크탑).
  ShellLocation? get returnTo => _returnTo;
  ShellLocation? _returnTo;

  @override
  ShellLocation build() => ShellLocation.today;

  void go(ShellLocation location) {
    _returnTo = null;
    state = location;
  }

  /// [from] — 들어온 화면. 뒤로가기·앱바 ← 가 여기로 돌아간다.
  void openCategory(String categoryId, {ShellLocation? from}) {
    _returnTo = from;
    state = ShellLocation.category(categoryId);
  }
}

/// 메인 영역 위치 — 사이드바·하단 네비·단축키·화면 안 링크가 모두 이걸 바꾼다.
final shellLocationProvider =
    NotifierProvider<ShellLocationNotifier, ShellLocation>(
      ShellLocationNotifier.new,
    );

class GroupScopeNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? groupId) => state = groupId;
}

/// 오늘·전체보기의 그룹 필터 — null 이면 전체. 두 화면이 같은 값을 공유한다
/// ("지금 보고 있는 그룹"). 예전 그룹 화면([오늘|전체보기] 탭)을 대신한다.
///
/// 이미 삭제·보관된 그룹 id 가 남아 있을 수 있으니 쓰는 쪽에서 활성 그룹과 대조한다.
final groupScopeProvider = NotifierProvider<GroupScopeNotifier, String?>(
  GroupScopeNotifier.new,
);
