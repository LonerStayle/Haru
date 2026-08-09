import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/policies/todo_sort_policy.dart';

/// 정렬 모드 영속 저장소. 구현을 갈아끼울 수 있게 인터페이스로 둔다
/// (테스트는 인메모리 fake 를 주입 — shared_preferences 플랫폼 채널 불필요).
abstract interface class SortModePreference {
  Future<TodoSortMode> load();

  Future<void> save(TodoSortMode mode);
}

/// shared_preferences 기반 기본 구현 — macOS / Android 각각의 로컬 설정에 저장된다
/// (기기 간 동기화 대상 아님 — 화면 보기 방식은 기기별 취향).
class SharedPrefsSortModePreference implements SortModePreference {
  const SharedPrefsSortModePreference();

  static const String storageKey = 'todo_sort_mode';

  @override
  Future<TodoSortMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TodoSortMode.fromStorage(prefs.getString(storageKey));
  }

  @override
  Future<void> save(TodoSortMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, mode.storageValue);
  }
}

final sortModePreferenceProvider = Provider<SortModePreference>(
  (ref) => const SharedPrefsSortModePreference(),
);

/// 목록 정렬 모드 (수동 ↔ 일정순) 의 전역 상태.
///
/// 카테고리 화면의 토글 버튼 하나가 이 상태를 바꾸고, 같은 상태를 하위 상세 화면
/// (체크리스트) 도 함께 본다 — 한 번 켜면 하위 목록까지 같은 순서로 보인다.
///
/// 저장된 값은 앱 시작 직후 비동기로 복원된다. 복원 전 기본값은 [TodoSortMode.manual].
/// 복원이 끝나기 전에 사용자가 직접 토글했다면 그 선택이 우선한다 (저장값이 덮어쓰지 않음).
class SortModeNotifier extends Notifier<TodoSortMode> {
  /// 저장값 복원이 끝나는 Future. 테스트 / 초기화 대기용.
  late Future<void> restored;

  bool _userChanged = false;
  bool _disposed = false;

  @override
  TodoSortMode build() {
    _userChanged = false;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    return TodoSortMode.manual;
  }

  Future<void> _restore() async {
    final TodoSortMode loaded;
    try {
      loaded = await ref.read(sortModePreferenceProvider).load();
    } catch (_) {
      // 저장소를 못 읽으면 기본(수동) 유지 — 정렬은 보기 설정일 뿐이라 조용히 넘어간다.
      return;
    }
    if (_disposed || _userChanged) return;
    state = loaded;
  }

  /// 버튼 한 번 — 수동 ↔ 일정순 전환 후 저장.
  Future<void> toggle() => setMode(state.toggled);

  Future<void> setMode(TodoSortMode mode) async {
    _userChanged = true;
    state = mode;
    try {
      await ref.read(sortModePreferenceProvider).save(mode);
    } catch (_) {
      // 저장 실패해도 이번 세션 동안은 선택이 유지된다 (UI 로 에러를 올리지 않는다).
    }
  }
}

final sortModeProvider = NotifierProvider<SortModeNotifier, TodoSortMode>(
  SortModeNotifier.new,
);
