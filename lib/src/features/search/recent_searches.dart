import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui_prefs.dart';

/// 최근 검색어 — 최신이 앞, 최대 [recentSearchLimit]개. 기기별 로컬 저장.
///
/// 글자를 칠 때마다가 아니라 결과를 열었을 때(또는 Enter) 기록한다 — 치다 만
/// 조각들이 목록을 채우지 않게.
class RecentSearchesNotifier extends Notifier<List<String>> {
  static const String storageKey = 'search.recent';

  bool _disposed = false;
  bool _userChanged = false;

  /// 복원이 끝나는 Future — 테스트 대기용.
  late Future<void> restored;

  @override
  List<String> build() {
    _disposed = false;
    _userChanged = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    return const <String>[];
  }

  Future<void> _restore() async {
    List<String> loaded;
    try {
      loaded = await ref.read(uiPrefsStoreProvider).loadList(storageKey);
    } catch (_) {
      return;
    }
    if (_disposed) return;
    if (!_userChanged) {
      state = List.unmodifiable(loaded.take(recentSearchLimit));
      return;
    }
    // 복원 전에 기록한 것이 있으면 그 위에 저장값을 이어 붙인다(덮어쓰지 않게).
    _set(
      [
        ...state,
        ...loaded.where((e) => !state.contains(e)),
      ].take(recentSearchLimit).toList(),
    );
  }

  /// [query] 를 맨 앞에 기록(중복은 앞으로 끌어올림). 빈 검색어는 무시.
  void record(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final next = [q, ...state.where((e) => e != q)].take(recentSearchLimit);
    _set(next.toList());
  }

  void remove(String query) => _set(state.where((e) => e != query).toList());

  void clear() => _set(const []);

  void _set(List<String> next) {
    _userChanged = true;
    state = List.unmodifiable(next);
    ref
        .read(uiPrefsStoreProvider)
        .saveList(storageKey, state)
        .catchError((_) {});
  }
}

const int recentSearchLimit = 5;

final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
      RecentSearchesNotifier.new,
    );
