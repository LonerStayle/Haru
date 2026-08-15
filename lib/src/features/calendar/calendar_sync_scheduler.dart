import 'dart:async';

import 'package:flutter/widgets.dart';

import 'calendar_sync_coordinator.dart';

/// 자동 동기화 트리거.
///
/// 이 앱에는 [WidgetsBindingObserver] 를 쓰는 곳이 한 군데도 없었다 — 캘린더
/// 연동이 처음으로 "앱이 다시 앞으로 나왔을 때" 를 알아야 하는 기능이다.
///
/// 트리거는 셋:
/// - **시작 직후 1회** — 다른 기기에서 바뀐 내용을 바로 반영
/// - **포그라운드 복귀** — macOS 는 창 포커스, Android 는 앱 전환 복귀에서 발생
/// - **주기** (기본 5분) — 앱이 떠 있는 동안만. `paused` 면 타이머를 멈춘다
///
/// 실시간(수 초)을 노리지 않는 이유는 구글 API 쿼터와 배터리다. Supabase 쪽
/// 실시간 동기화와 달리 캘린더는 사람이 다른 앱에서 고치는 빈도가 훨씬 낮다.
class CalendarSyncScheduler with WidgetsBindingObserver {
  CalendarSyncScheduler({
    required this.coordinator,
    required this.autoSyncEnabled,
    this.interval = const Duration(minutes: 5),
  });

  final CalendarSyncCoordinator coordinator;

  /// 호출 시점의 자동 동기화 설정 — 사용자가 끄면 다음 tick 부터 멈춘다.
  final bool Function() autoSyncEnabled;

  final Duration interval;

  Timer? _timer;
  bool _started = false;

  /// 앱 시작 시 1회 호출. 즉시 한 번 돌리고 주기 타이머를 건다.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_tick());
    _restartTimer();
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  /// 사용자가 "지금 동기화" 를 눌렀을 때 — 자동 동기화 설정과 무관하게 돈다.
  Future<void> syncNow() => coordinator.syncNow();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_tick());
        _restartTimer();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 백그라운드에서까지 돌 이유가 없다 — 쿼터와 배터리만 쓴다.
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!autoSyncEnabled()) return;
    await coordinator.syncNow();
  }
}
