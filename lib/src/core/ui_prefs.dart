import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 화면 보기 상태(접힘·펼침 등) 영속 저장소 — [SortModePreference] 와 같은 모양.
///
/// 기기별 로컬 설정이다(동기화 대상 아님). 테스트는 인메모리 구현을 주입한다.
abstract interface class UiPrefsStore {
  Future<Set<String>> loadIds(String key);

  Future<void> saveIds(String key, Set<String> ids);
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
}

/// 인메모리 구현 — 테스트용 (앱 재시작 시뮬레이션은 같은 인스턴스를 다시 주입).
class MemoryUiPrefsStore implements UiPrefsStore {
  final Map<String, Set<String>> data = {};

  @override
  Future<Set<String>> loadIds(String key) async => {...?data[key]};

  @override
  Future<void> saveIds(String key, Set<String> ids) async =>
      data[key] = {...ids};
}

final uiPrefsStoreProvider = Provider<UiPrefsStore>(
  (ref) => const SharedPrefsUiPrefsStore(),
);

/// 키 하나에 묶인 id 집합(예: 접힌 그룹 id 들) — 앱을 다시 켜도 유지된다.
///
/// 저장값은 시작 직후 비동기로 복원된다. 복원 전에 사용자가 바꿨다면 그 선택이
/// 우선한다([SortModeNotifier] 와 같은 규칙). 저장소 오류는 조용히 넘어간다 — 보기
/// 상태일 뿐이라 이번 세션 동안만 유지돼도 괜찮다.
class PersistedIdSet extends Notifier<Set<String>> {
  PersistedIdSet(this.key);

  final String key;

  bool _userChanged = false;
  bool _disposed = false;

  /// 복원이 끝나는 Future — 테스트 대기용.
  late Future<void> restored;

  @override
  Set<String> build() {
    _userChanged = false;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    return const <String>{};
  }

  Future<void> _restore() async {
    final Set<String> loaded;
    try {
      loaded = await ref.read(uiPrefsStoreProvider).loadIds(key);
    } catch (_) {
      return;
    }
    if (_disposed || _userChanged) return;
    state = loaded;
  }

  bool contains(String id) => state.contains(id);

  void toggle(String id) =>
      replace(state.contains(id) ? ({...state}..remove(id)) : {...state, id});

  void set(String id, bool present) {
    if (state.contains(id) == present) return;
    toggle(id);
  }

  void replace(Set<String> ids) {
    _userChanged = true;
    state = Set.unmodifiable(ids);
    _save();
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
