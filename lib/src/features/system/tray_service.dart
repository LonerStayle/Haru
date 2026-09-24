import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../core/platform.dart';

/// macOS 메뉴바 트레이 통합. icon + title (미체크 카운트) + 컨텍스트 메뉴.
///
/// 비-macOS 플랫폼에서는 모든 메서드가 no-op. method channel 예외도 graceful.
class TrayService with TrayListener {
  TrayService({required this.onAddTodo, required this.onQuit});

  final VoidCallback onAddTodo;
  final VoidCallback onQuit;

  static const _iconAsset = 'assets/tray_icon.png';

  bool _initialized = false;

  Future<void> init() async {
    if (!AppPlatform.isDesktop) return;
    try {
      await trayManager.setIcon(_iconAsset, isTemplate: true);
      await trayManager.setToolTip('하루');
      await _rebuildMenu(undoneCount: 0);
      trayManager.addListener(this);
      _initialized = true;
    } catch (e) {
      debugPrint('[solo_todo] tray 초기화 실패: $e');
    }
  }

  /// 미체크 카운트가 변경될 때마다 호출 (Riverpod listener 가 wiring).
  /// 0 이면 title 비우고 메뉴 라벨도 "오늘 0건" 으로 갱신.
  Future<void> updateUndoneCount(int count) async {
    if (!_initialized) return;
    try {
      await trayManager.setTitle(count > 0 ? '$count' : '');
      await _rebuildMenu(undoneCount: count);
    } catch (e) {
      debugPrint('[solo_todo] tray title 갱신 실패: $e');
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

  Future<void> _rebuildMenu({required int undoneCount}) async {
    final menu = Menu(
      items: [
        MenuItem(label: '오늘 $undoneCount건 미체크', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'add', label: '새 할 일 (⌘⇧N)', onClick: (_) => onAddTodo()),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '종료', onClick: (_) => onQuit()),
      ],
    );
    await trayManager.setContextMenu(menu);
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
