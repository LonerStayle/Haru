import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/category.dart';
import 'calendar_event.dart';
import 'calendar_settings.dart';
import 'calendar_sync_service.dart';

/// 한 번의 동기화 결과 요약. UI 가 상태를 보여주는 데 쓴다.
class SyncOutcome {
  const SyncOutcome({
    required this.push,
    required this.pull,
    this.skipped = false,
    this.failed = false,
  });

  const SyncOutcome.skipped()
    : push = const PushResult(),
      pull = const PullResult(),
      skipped = true,
      failed = false;

  /// 도중에 예외로 실패 — "지금 동기화" 가 성공으로 오인하지 않게 따로 구분한다.
  const SyncOutcome.failed()
    : push = const PushResult(),
      pull = const PullResult(),
      skipped = true,
      failed = true;

  final PushResult push;
  final PullResult pull;

  /// 연동이 꺼져 있거나 이미 진행 중이라 아무것도 하지 않았는가.
  final bool skipped;

  /// 예외로 실패했는가.
  final bool failed;

  /// 재인증이 필요한가 — 어느 방향에서든 걸리면 설정 화면이 "다시 연결" 을 띄운다.
  bool get authRequired => push.authRequired || pull.authRequired;
}

/// push 와 pull 을 순서대로 돌리고 그 결과를 설정에 반영하는 오케스트레이터.
///
/// **push 를 먼저 한다.** 앱에서 방금 고친 내용을 캘린더에 올린 뒤에 받아와야,
/// 아직 안 올라간 로컬 변경이 "캘린더가 더 최신" 으로 오판돼 되덮이는 일이 없다.
///
/// **서비스 하나당 인스턴스 하나**다 ([service] 가 담당하는 provider 를 그대로
/// 따른다). 구글과 Microsoft 를 한 코디네이터에 몰아넣지 않는 이유는 실패 격리다 —
/// 한쪽 재인증이 필요해도 다른 쪽 동기화는 계속 돌아야 한다.
class CalendarSyncCoordinator {
  CalendarSyncCoordinator({
    required this.service,
    required this.preference,
    required this.readSettings,
    required this.writeSettings,
    required this.activeCategories,
  });

  final CalendarSyncService service;
  final CalendarSettingsPreference preference;

  /// 현재 설정 스냅샷.
  final CalendarSettings Function() readSettings;

  /// 설정 갱신 — Notifier 를 통해 UI 에도 즉시 반영되게 한다.
  final void Function(CalendarSettings) writeSettings;

  /// 유입 항목의 카테고리 후보 (보관된 것 제외).
  final List<Category> Function() activeCategories;

  /// 이 코디네이터가 담당하는 서비스.
  CalendarProvider get provider => service.provider;

  bool _running = false;

  Future<SyncOutcome> syncNow() async {
    final settings = readSettings();
    if (!settings.viewFor(provider).connected || _running) {
      return const SyncOutcome.skipped();
    }
    _running = true;
    try {
      final push = await service.flushPending();
      // 재인증이 필요하면 받아오기도 같은 실패다 — 두 번 실패시키지 않는다.
      if (push.authRequired) {
        return SyncOutcome(push: push, pull: const PullResult());
      }

      final pull = await service.pull(
        settings: settings,
        categoryFor: _categoryFor,
      );
      await _persist(pull);
      return SyncOutcome(push: push, pull: pull);
    } catch (e) {
      // 동기화 실패가 앱을 멈추게 해선 안 된다. 다음 회차에 다시 시도한다.
      debugPrint('[solo_todo] 캘린더 동기화 실패: $e');
      return const SyncOutcome.failed();
    } finally {
      _running = false;
    }
  }

  /// 수신 결과를 설정에 반영한다 — 새 토큰과 마지막 동기화 시각.
  /// 자기 provider 의 칸만 건드린다 — 다른 서비스의 토큰을 날리면 그쪽이 다음
  /// 회차에 전체 재수집으로 떨어진다.
  Future<void> _persist(PullResult pull) async {
    final current = readSettings();
    final view = current.viewFor(provider);
    final tokens = Map<String, String>.of(view.syncTokens);
    for (final entry in pull.newSyncTokens.entries) {
      tokens[entry.key] = entry.value;
      await preference.setSyncToken(provider, entry.key, entry.value);
    }
    // 만료됐는데 새 토큰도 못 받은 캘린더는 다음 회차가 전체 재수집으로 가야 한다.
    for (final calendarId in pull.expiredCalendars) {
      if (pull.newSyncTokens.containsKey(calendarId)) continue;
      tokens.remove(calendarId);
      await preference.clearSyncToken(provider, calendarId);
    }

    writeSettings(
      current.withConnection(
        provider,
        view.copyWith(syncTokens: tokens, lastSyncedAt: DateTime.now()),
      ),
    );
  }

  /// 유입 항목이 들어갈 카테고리.
  ///
  /// 캘린더별 매핑 → 기본 카테고리 → 첫 활성 카테고리 순으로 떨어진다. 매핑 대상이
  /// 삭제·보관됐을 수 있어 매번 활성 목록과 대조한다 — 없는 카테고리로 할 일을
  /// 만들면 어느 화면에도 안 보이는 유령이 된다.
  Category _categoryFor(String calendarId) {
    final settings = readSettings();
    final actives = activeCategories();
    if (actives.isEmpty) return Category.daily;

    Category? pick(String? id) {
      if (id == null || id.isEmpty) return null;
      for (final c in actives) {
        if (c.id == id) return c;
      }
      return null;
    }

    return pick(settings.viewFor(provider).categoryMap[calendarId]) ??
        pick(settings.defaultCategoryId) ??
        actives.first;
  }
}
