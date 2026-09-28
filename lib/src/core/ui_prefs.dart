import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 화면 보기 상태(접힘·펼침 등) 영속 저장소 — [SortModePreference] 와 같은 모양.
///
/// 기기별 로컬 설정이다(동기화 대상 아님). 테스트는 인메모리 구현을 주입한다.
abstract interface class UiPrefsStore {
  Future<Set<String>> loadIds(String key);

  Future<void> saveIds(String key, Set<String> ids);

  /// 순서가 있는 문자열 목록 (최근 검색어 등). 저장한 순서 그대로 돌아온다.
  Future<List<String>> loadList(String key);

  Future<void> saveList(String key, List<String> values);
}

/// shared_preferences 기반 기본 구현. 키는 `ui.<key>` 로 저장된다.
class SharedPrefsUiPrefsStore implements UiPrefsStore {
  const SharedPrefsUiPrefsStore();

  @override
  Future<Set<String>> loadIds(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('ui.$key') ?? const <String>[]).toSet();
  }

  @override
  Future<void> saveIds(String key, Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ui.$key', ids.toList()..sort());
  }

  @override
  Future<List<String>> loadList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('ui.list.$key') ?? const <String>[];
  }

  @override
  Future<void> saveList(String key, List<String> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ui.list.$key', values);
  }
}

/// 인메모리 구현 — 테스트용 (앱 재시작 시뮬레이션은 같은 인스턴스를 다시 주입).
class MemoryUiPrefsStore implements UiPrefsStore {
  final Map<String, Set<String>> data = {};

  @override
  Future<Set<String>> loadIds(String key) async => {...?data[key]};

  @override
  Future<void> saveIds(String key, Set<String> ids) async =>
      data[key] = {...ids};

  final Map<String, List<String>> lists = {};

  @override
  Future<List<String>> loadList(String key) async => [...?lists[key]];

  @override
  Future<void> saveList(String key, List<String> values) async =>
      lists[key] = [...values];
}

/// 앱 시작 전에 미리 읽어 둔 값(키 → 목록) — 테마처럼 첫 프레임부터 맞아야 하는 설정용.
/// main 이 SharedPreferences 에서 읽어 override 한다. 기본은 비어 있음(비동기 복원).
final preloadedUiListsProvider = Provider<Map<String, List<String>>>(
  (ref) => const {},
);

/// [preloadedUiListsProvider] 에 넣을 값 읽기 — 실패하면 빈 맵(비동기 복원으로 대체).
Future<Map<String, List<String>>> preloadUiLists(List<String> keys) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return {for (final k in keys) k: ?prefs.getStringList('ui.list.$k')};
  } catch (_) {
    return const {};
  }
}

final uiPrefsStoreProvider = Provider<UiPrefsStore>(
  (ref) => const SharedPrefsUiPrefsStore(),
);

/// 키 하나에 묶인 id 집합(예: 접힌 그룹 id 들) — 앱을 다시 켜도 유지된다.
///
/// 저장값은 시작 직후 비동기로 복원된다. 복원 전에 사용자가 바꾼 것이 있으면 저장값
/// 위에 그 변경(넣기/빼기)만 다시 얹는다 — 집합을 통째로 덮으면 다른 항목의 저장값이
/// 날아간다. 저장소 오류는 조용히 넘어간다 — 보기 상태일 뿐이다.
class PersistedIdSet extends Notifier<Set<String>> {
  PersistedIdSet(this.key);

  final String key;

  bool _restoring = true;
  bool _disposed = false;

  /// 복원 전에 들어온 변경 — (id, 넣기 여부). 복원 후 저장값 위에 다시 얹는다.
  final List<(String, bool)> _pending = [];

  /// 복원이 끝나는 Future — 테스트 대기용.
  late Future<void> restored;

  @override
  Set<String> build() {
    _restoring = true;
    _pending.clear();
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    return const <String>{};
  }

  Future<void> _restore() async {
    Set<String>? loaded;
    try {
      loaded = await ref.read(uiPrefsStoreProvider).loadIds(key);
    } catch (_) {
      loaded = null;
    }
    if (_disposed) return;
    _restoring = false;
    if (loaded == null) return;
    final merged = {...loaded};
    for (final (id, present) in _pending) {
      present ? merged.add(id) : merged.remove(id);
    }
    final hadPending = _pending.isNotEmpty;
    _pending.clear();
    state = Set.unmodifiable(merged);
    if (hadPending) _save();
  }

  bool contains(String id) => state.contains(id);

  void toggle(String id) => set(id, !state.contains(id));

  void set(String id, bool present) {
    if (state.contains(id) == present) return;
    replace(present ? {...state, id} : ({...state}..remove(id)));
  }

  void replace(Set<String> ids) {
    if (_restoring) {
      // 바뀐 것만 기록 — 복원 후 저장값 위에 얹는다.
      for (final id in ids.difference(state)) {
        _pending.add((id, true));
      }
      for (final id in state.difference(ids)) {
        _pending.add((id, false));
      }
    }
    state = Set.unmodifiable(ids);
    if (!_restoring) _save();
  }

  Future<void> _save() async {
    try {
      await ref.read(uiPrefsStoreProvider).saveIds(key, state);
    } catch (_) {
      // 저장 실패 — 이번 세션 동안은 유지된다.
    }
  }
}

/// 키별 영속 id 집합. 예: `persistedIdSetProvider('outline.collapsed')`.
final persistedIdSetProvider =
    NotifierProvider.family<PersistedIdSet, Set<String>, String>(
      PersistedIdSet.new,
    );
