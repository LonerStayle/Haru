import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Google Calendar 연동 설정 스냅샷 — 설정 화면과 동기화 서비스가 함께 보는 단일 상태.
///
/// - [connected] — Google 계정 연동 완료 여부.
/// - [writeCalendarId] — 새 할 일을 등록할 캘린더 1개. 기본값 `'primary'`.
/// - [readCalendarIds] — 구글 → 앱으로 가져올 캘린더 N개. 순서는 의미 없고 중복 없음.
/// - [categoryMap] — 캘린더 id → 카테고리 id. 그 캘린더에서 들어온 이벤트를 어느
///   카테고리에 넣을지 결정한다. 매핑이 없는 캘린더는 [defaultCategoryId] 로 떨어진다.
/// - [defaultCategoryId] — 빈 문자열이면 "지정 안 됨" — 호출자가 첫 활성 카테고리로
///   해석한다.
/// - [importInvited] — 내가 만들지 않고 초대만 받은 이벤트도 가져올지.
/// - [autoSync] — 백그라운드 자동 동기화 여부.
/// - [syncTokens] — 캘린더 id → 구글 증분 동기화 토큰(nextSyncToken). 캘린더별로
///   따로 만료되므로 맵 전체가 아니라 항목 단위로 갱신/삭제한다
///   ([CalendarSettingsPreference.setSyncToken] / [clearSyncToken] 참고).
/// - [lastSyncedAt] — 마지막 동기화 완료 시각. 아직 한 번도 안 돌았으면 null.
/// - [defaultAddToCalendar] — 할 일 편집 시트의 "캘린더에 등록" 토글의 마지막 선택.
class CalendarSettings {
  const CalendarSettings({
    this.connected = false,
    this.writeCalendarId = 'primary',
    this.readCalendarIds = const ['primary'],
    this.categoryMap = const {},
    this.defaultCategoryId = '',
    this.importInvited = false,
    this.autoSync = true,
    this.syncTokens = const {},
    this.lastSyncedAt,
    this.defaultAddToCalendar = false,
  });

  final bool connected;
  final String writeCalendarId;
  final List<String> readCalendarIds;
  final Map<String, String> categoryMap;
  final String defaultCategoryId;
  final bool importInvited;
  final bool autoSync;
  final Map<String, String> syncTokens;
  final DateTime? lastSyncedAt;
  final bool defaultAddToCalendar;

  /// [lastSyncedAt] 은 nullable 이라 `null` 을 넘겨도 "값 유지" 로 보일 수 있어
  /// [clearLastSyncedAt] 플래그로 명시적으로 비운다.
  CalendarSettings copyWith({
    bool? connected,
    String? writeCalendarId,
    List<String>? readCalendarIds,
    Map<String, String>? categoryMap,
    String? defaultCategoryId,
    bool? importInvited,
    bool? autoSync,
    Map<String, String>? syncTokens,
    DateTime? lastSyncedAt,
    bool clearLastSyncedAt = false,
    bool? defaultAddToCalendar,
  }) {
    return CalendarSettings(
      connected: connected ?? this.connected,
      writeCalendarId: writeCalendarId ?? this.writeCalendarId,
      readCalendarIds: readCalendarIds ?? this.readCalendarIds,
      categoryMap: categoryMap ?? this.categoryMap,
      defaultCategoryId: defaultCategoryId ?? this.defaultCategoryId,
      importInvited: importInvited ?? this.importInvited,
      autoSync: autoSync ?? this.autoSync,
      syncTokens: syncTokens ?? this.syncTokens,
      lastSyncedAt: clearLastSyncedAt
          ? null
          : (lastSyncedAt ?? this.lastSyncedAt),
      defaultAddToCalendar: defaultAddToCalendar ?? this.defaultAddToCalendar,
    );
  }
}

/// [CalendarSettings] 영속 저장소. 구현을 갈아끼울 수 있게 인터페이스로 둔다
/// (테스트는 인메모리 fake 를 주입 — shared_preferences 플랫폼 채널 불필요).
abstract interface class CalendarSettingsPreference {
  Future<CalendarSettings> load();

  Future<void> save(CalendarSettings settings);

  /// syncTokens 맵의 [calendarId] 항목만 갱신 — 동기화 폴링마다 설정 전체를
  /// 다시 읽고 다시 쓰지 않는다.
  Future<void> setSyncToken(String calendarId, String token);

  /// 토큰 만료 시 그 캘린더 것만 버린다 (다음 동기화가 전체 재수집으로 넘어가게).
  Future<void> clearSyncToken(String calendarId);
}

/// shared_preferences 기반 기본 구현 — macOS / Android 각각의 로컬 설정에 저장된다
/// (기기 간 동기화 대상 아님 — Supabase 의 `todos` 테이블과 달리 연동 설정 자체는
/// 기기별로 따로 관리한다).
///
/// 리스트/맵 값은 JSON 문자열로 인코딩해 저장한다. 저장된 값이 없거나(null), 깨졌거나
/// (jsonDecode 실패), 기대한 타입이 아니면 예외를 던지지 않고 기본값으로 폴백한다 —
/// 설정 하나가 깨졌다고 앱이 못 뜨면 안 된다.
class SharedPrefsCalendarSettingsPreference
    implements CalendarSettingsPreference {
  const SharedPrefsCalendarSettingsPreference();

  static const String _connectedKey = 'gcal.connected';
  static const String _writeCalendarIdKey = 'gcal.writeCalendarId';
  static const String _readCalendarIdsKey = 'gcal.readCalendarIds';
  static const String _categoryMapKey = 'gcal.categoryMap';
  static const String _defaultCategoryIdKey = 'gcal.defaultCategoryId';
  static const String _importInvitedKey = 'gcal.importInvited';
  static const String _autoSyncKey = 'gcal.autoSync';
  static const String _syncTokensKey = 'gcal.syncTokens';
  static const String _lastSyncedAtKey = 'gcal.lastSyncedAt';
  static const String _defaultAddToCalendarKey = 'gcal.defaultAddToCalendar';

  @override
  Future<CalendarSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return CalendarSettings(
      connected: prefs.getBool(_connectedKey) ?? false,
      writeCalendarId: prefs.getString(_writeCalendarIdKey) ?? 'primary',
      readCalendarIds:
          _decodeStringSet(prefs.getString(_readCalendarIdsKey))?.toList() ??
          const ['primary'],
      categoryMap:
          _decodeStringMap(prefs.getString(_categoryMapKey)) ?? const {},
      defaultCategoryId: prefs.getString(_defaultCategoryIdKey) ?? '',
      importInvited: prefs.getBool(_importInvitedKey) ?? false,
      autoSync: prefs.getBool(_autoSyncKey) ?? true,
      syncTokens: _decodeStringMap(prefs.getString(_syncTokensKey)) ?? const {},
      lastSyncedAt: _decodeDateTime(prefs.getString(_lastSyncedAtKey)),
      defaultAddToCalendar: prefs.getBool(_defaultAddToCalendarKey) ?? false,
    );
  }

  @override
  Future<void> save(CalendarSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_connectedKey, settings.connected);
    await prefs.setString(_writeCalendarIdKey, settings.writeCalendarId);
    await prefs.setString(
      _readCalendarIdsKey,
      jsonEncode(settings.readCalendarIds.toSet().toList()),
    );
    await prefs.setString(_categoryMapKey, jsonEncode(settings.categoryMap));
    await prefs.setString(_defaultCategoryIdKey, settings.defaultCategoryId);
    await prefs.setBool(_importInvitedKey, settings.importInvited);
    await prefs.setBool(_autoSyncKey, settings.autoSync);
    await prefs.setString(_syncTokensKey, jsonEncode(settings.syncTokens));
    final lastSyncedAt = settings.lastSyncedAt;
    if (lastSyncedAt == null) {
      await prefs.remove(_lastSyncedAtKey);
    } else {
      await prefs.setString(_lastSyncedAtKey, lastSyncedAt.toIso8601String());
    }
    await prefs.setBool(
      _defaultAddToCalendarKey,
      settings.defaultAddToCalendar,
    );
  }

  @override
  Future<void> setSyncToken(String calendarId, String token) async {
    final prefs = await SharedPreferences.getInstance();
    final tokens = _decodeStringMap(prefs.getString(_syncTokensKey)) ?? {};
    final updated = Map<String, String>.of(tokens)..[calendarId] = token;
    await prefs.setString(_syncTokensKey, jsonEncode(updated));
  }

  @override
  Future<void> clearSyncToken(String calendarId) async {
    final prefs = await SharedPreferences.getInstance();
    final tokens = _decodeStringMap(prefs.getString(_syncTokensKey)) ?? {};
    if (!tokens.containsKey(calendarId)) return;
    final updated = Map<String, String>.of(tokens)..remove(calendarId);
    await prefs.setString(_syncTokensKey, jsonEncode(updated));
  }

  /// JSON 문자열 → 중복 제거된 문자열 집합. 저장값이 없거나(null) 깨졌거나
  /// (jsonDecode 실패) 리스트가 아니거나 원소가 문자열이 아니면 null 반환 —
  /// 호출자가 기본값으로 폴백한다.
  static Set<String>? _decodeStringSet(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final result = <String>{};
      for (final item in decoded) {
        if (item is! String) return null;
        result.add(item);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// JSON 문자열 → `Map<String, String>`. 저장값이 없거나 깨졌거나 맵이 아니거나
  /// 키/값이 문자열이 아니면 null 반환 — 호출자가 기본값으로 폴백한다.
  static Map<String, String>? _decodeStringMap(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) return null;
        result[key] = value;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// ISO8601 문자열 → [DateTime]. 저장값이 없거나 파싱 불가면 null.
  static DateTime? _decodeDateTime(String? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }
}

final calendarSettingsPreferenceProvider = Provider<CalendarSettingsPreference>(
  (ref) => const SharedPrefsCalendarSettingsPreference(),
);

/// Google Calendar 연동 설정의 전역 상태.
///
/// 저장된 값은 앱 시작 직후 비동기로 복원된다. 복원 전 기본값은 [CalendarSettings] 의
/// 기본 생성자 값(미연결 · 쓰기/읽기 캘린더 `primary` · autoSync 켜짐). 복원이 끝나기
/// 전에 사용자가 직접 값을 바꿨다면 그 선택이 우선한다 (저장값이 덮어쓰지 않음).
class CalendarSettingsNotifier extends Notifier<CalendarSettings> {
  /// 저장값 복원이 끝나는 Future. 테스트 / 초기화 대기용.
  late Future<void> restored;

  bool _userChanged = false;
  bool _disposed = false;

  @override
  CalendarSettings build() {
    _userChanged = false;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    restored = _restore();
    return const CalendarSettings();
  }

  Future<void> _restore() async {
    final CalendarSettings loaded;
    try {
      loaded = await ref.read(calendarSettingsPreferenceProvider).load();
    } catch (_) {
      // 저장소를 못 읽으면 기본값 유지 — 연동 설정 하나 때문에 앱이 못 뜨면 안 된다.
      return;
    }
    if (_disposed || _userChanged) return;
    state = loaded;
  }

  /// 현재 값을 [transform] 으로 바꾸고 전체를 저장. 설정 화면의 일반 필드
  /// (연결 여부, 쓰기/읽기 캘린더, 카테고리 매핑 등)에 쓴다.
  Future<void> update(
    CalendarSettings Function(CalendarSettings current) transform,
  ) async {
    _userChanged = true;
    final next = transform(state);
    state = next;
    try {
      await ref.read(calendarSettingsPreferenceProvider).save(next);
    } catch (_) {
      // 저장 실패해도 이번 세션 동안은 선택이 유지된다 (UI 로 에러를 올리지 않는다).
    }
  }

  /// 캘린더 하나의 동기화 토큰만 갱신 (설정 전체를 다시 쓰지 않는다).
  Future<void> setSyncToken(String calendarId, String token) async {
    _userChanged = true;
    final tokens = Map<String, String>.of(state.syncTokens)
      ..[calendarId] = token;
    state = state.copyWith(syncTokens: tokens);
    try {
      await ref
          .read(calendarSettingsPreferenceProvider)
          .setSyncToken(calendarId, token);
    } catch (_) {
      // 저장 실패해도 이번 세션 동안은 선택이 유지된다.
    }
  }

  /// 토큰 만료 시 그 캘린더 것만 버린다.
  Future<void> clearSyncToken(String calendarId) async {
    _userChanged = true;
    if (!state.syncTokens.containsKey(calendarId)) return;
    final tokens = Map<String, String>.of(state.syncTokens)..remove(calendarId);
    state = state.copyWith(syncTokens: tokens);
    try {
      await ref
          .read(calendarSettingsPreferenceProvider)
          .clearSyncToken(calendarId);
    } catch (_) {
      // 저장 실패해도 이번 세션 동안은 선택이 유지된다.
    }
  }
}

final calendarSettingsProvider =
    NotifierProvider<CalendarSettingsNotifier, CalendarSettings>(
      CalendarSettingsNotifier.new,
    );
