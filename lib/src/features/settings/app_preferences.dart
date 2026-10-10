import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui_prefs.dart';

/// 값 하나짜리 기기별 설정 — [UiPrefsStore] 의 목록 저장에 한 칸만 쓴다.
///
/// 저장값은 시작 직후 비동기로 복원된다. 복원 전에 사용자가 바꿨으면 그 선택이 이긴다
/// ([SortModeNotifier] 와 같은 규칙). 저장소 오류는 조용히 넘어간다 — 보기 설정일 뿐이다.
abstract class SinglePrefNotifier<T> extends Notifier<T> {
  String get storageKey;
  T get fallback;
  T decode(String? raw);
  String? encode(T value);

  bool _userChanged = false;
  bool _disposed = false;

  /// 복원이 끝나는 Future — 테스트 대기용.
  late Future<void> restored;

  @override
  T build() {
    _userChanged = false;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    // 시작 전에 읽어 둔 값이 있으면 첫 프레임부터 그 값 — 테마 깜빡임·첫 ⌘N 의 기본
    // 카테고리 누락을 막는다.
    final pre = ref.read(preloadedUiListsProvider)[storageKey];
    return pre == null ? fallback : decode(pre.isEmpty ? null : pre.first);
  }

  Future<void> _restore() async {
    List<String> loaded;
    try {
      loaded = await ref.read(uiPrefsStoreProvider).loadList(storageKey);
    } catch (_) {
      return;
    }
    if (_disposed || _userChanged) return;
    state = decode(loaded.isEmpty ? null : loaded.first);
  }

  Future<void> set(T value) async {
    _userChanged = true;
    state = value;
    final raw = encode(value);
    try {
      await ref
          .read(uiPrefsStoreProvider)
          .saveList(storageKey, raw == null ? const [] : [raw]);
    } catch (_) {
      // 저장 실패 — 이번 세션 동안은 유지된다.
    }
  }
}

/// 화면 테마 — 시스템 따라가기 / 라이트 / 다크.
class ThemeModeNotifier extends SinglePrefNotifier<ThemeMode> {
  @override
  String get storageKey => 'app.themeMode';

  @override
  ThemeMode get fallback => ThemeMode.system;

  @override
  ThemeMode decode(String? raw) => switch (raw) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  String encode(ThemeMode value) => value.name;
}

/// main 이 미리 읽어 둘 키들 ([preloadUiLists]).
const List<String> preloadedPrefKeys = [
  'app.themeMode',
  'app.defaultCategory',
  'ai.route',
];

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

/// 새 할 일의 기본 카테고리 — 오늘·전체보기·캘린더처럼 "지금 보는 카테고리" 가 없는
/// 화면에서 쓴다. null = 자동(마지막에 쓴 카테고리 → 사이드바 첫 카테고리). 카테고리 화면에서는 그 카테고리가
/// 우선이다.
class DefaultCategoryNotifier extends SinglePrefNotifier<String?> {
  @override
  String get storageKey => 'app.defaultCategory';

  @override
  String? get fallback => null;

  @override
  String? decode(String? raw) => raw;

  @override
  String? encode(String? value) => value;
}

final defaultCategoryIdProvider =
    NotifierProvider<DefaultCategoryNotifier, String?>(
      DefaultCategoryNotifier.new,
    );
