import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../core/platform.dart';

/// 트레이 메뉴에 올릴 오늘 할 일 한 줄.
@immutable
class TrayTodo {
  const TrayTodo({
    required this.id,
    required this.title,
    this.inProgress = false,
  });

  final String id;
  final String title;
  final bool inProgress;

  @override
  bool operator ==(Object other) =>
      other is TrayTodo &&
      other.id == id &&
      other.title == title &&
      other.inProgress == inProgress;

  @override
  int get hashCode => Object.hash(id, title, inProgress);
}

/// 트레이 메뉴 내용 — 이 값이 바뀔 때만 메뉴를 다시 만든다.
@immutable
class TrayState {
  const TrayState({
    this.top = const [],
    this.undoneCount = 0,
    this.pendingSync = 0,
  });

  /// 오늘 남은 할 일 앞쪽 몇 개 (메뉴에서 바로 체크).
  final List<TrayTodo> top;
  final int undoneCount;

  /// 서버에 아직 안 올라간 변경 수.
  final int pendingSync;

  @override
  bool operator ==(Object other) =>
      other is TrayState &&
      other.undoneCount == undoneCount &&
      other.pendingSync == pendingSync &&
      listEquals(other.top, top);

  @override
  int get hashCode =>
      Object.hash(undoneCount, pendingSync, Object.hashAll(top));
}

/// 트레이 메뉴에 보일 할 일 수.
const int trayTopLimit = 5;

/// macOS 메뉴바 트레이. 아이콘 + 제목(남은 수) + 메뉴:
///
///   하루 열기 / 오늘 남은 N건 + 앞쪽 5개(누르면 완료) / 새 할 일 ⌘⇧N / 설정 ⌘, /
///   동기화 상태 / 종료
///
/// 비-macOS 플랫폼에서는 모든 메서드가 no-op. method channel 예외도 graceful.
class TrayService with TrayListener {
  TrayService({
    required this.onOpen,
    required this.onAddTodo,
    required this.onOpenSettings,
    required this.onToggleTodo,
    required this.onQuit,
  });

  final VoidCallback onOpen;
  final VoidCallback onAddTodo;
  final VoidCallback onOpenSettings;
  final void Function(String todoId) onToggleTodo;
  final VoidCallback onQuit;

  static const _iconAsset = 'assets/tray_icon.png';

  bool _initialized = false;
  TrayState _state = const TrayState();

  Future<void> init() async {
    if (!AppPlatform.isDesktop) return;
    try {
      await trayManager.setIcon(_iconAsset, isTemplate: true);
      await trayManager.setToolTip('하루');
      await trayManager.setContextMenu(buildMenu(_state));
      trayManager.addListener(this);
      _initialized = true;
    } catch (e) {
      debugPrint('[solo_todo] tray 초기화 실패: $e');
    }
  }

  /// 오늘 할 일·동기화 상태가 바뀔 때마다 (셸의 listener 가 부른다).
  Future<void> update(TrayState next) async {
    if (next == _state) return;
    _state = next;
    if (!_initialized) return;
    try {
      await trayManager.setTitle(
        next.undoneCount > 0 ? '${next.undoneCount}' : '',
      );
      await trayManager.setContextMenu(buildMenu(next));
    } catch (e) {
      debugPrint('[solo_todo] tray 갱신 실패: $e');
    }
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      // 종료 단계 — 무시.
    }
    _initialized = false;
  }

  /// 메뉴 구성 — 테스트가 내용을 검증할 수 있게 공개.
  @visibleForTesting
  Menu buildMenu(TrayState state) {
    final more = state.undoneCount - state.top.length;
    return Menu(
      items: [
        MenuItem(key: 'open', label: '하루 열기', onClick: (_) => onOpen()),
        MenuItem.separator(),
        MenuItem(
          key: 'today',
          label: state.undoneCount == 0
              ? '오늘 남은 할 일 없음'
              : '오늘 남은 ${state.undoneCount}건 · 누르면 완료',
          disabled: true,
        ),
        for (final t in state.top)
          MenuItem(
            key: 'todo:${t.id}',
            label: '${t.inProgress ? '◐' : '○'}  ${_short(t.title)}',
            onClick: (_) => onToggleTodo(t.id),
          ),
        if (more > 0)
          MenuItem(
            key: 'more',
            label: '외 $more건 — 하루에서 보기',
            onClick: (_) => onOpen(),
          ),
        MenuItem.separator(),
        MenuItem(key: 'add', label: '새 할 일 (⌘⇧N)', onClick: (_) => onAddTodo()),
        MenuItem(
          key: 'settings',
          label: '설정… (⌘,)',
          onClick: (_) => onOpenSettings(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'sync',
          label: state.pendingSync > 0
              ? '동기화 대기 ${state.pendingSync}건'
              : '동기화됨',
          disabled: true,
        ),
        MenuItem(key: 'quit', label: '종료', onClick: (_) => onQuit()),
      ],
    );
  }

  /// 메뉴 한 줄은 짧게 — 긴 제목이 메뉴 폭을 화면만큼 늘린다.
  static String _short(String title) {
    final t = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length <= 32 ? t : '${t.substring(0, 31)}…';
  }

  // 좌클릭 — 메뉴 띄우기 (macOS native 기본은 좌클릭에 menu 가 안 뜨므로 강제).
  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }
}
