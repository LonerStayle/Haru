import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../category/categories_controller.dart';
import 'calendar_gateway.dart';
import 'calendar_settings.dart';
import 'google_auth_service.dart';
import 'google_calendar_gateway.dart';

// ---------------------------------------------------------------------------
// Providers — 이 화면과 (다음 wave 의) 동기화 서비스가 함께 볼 진입점들.
// ---------------------------------------------------------------------------

/// Google Calendar API 게이트웨이. [calendarAuthProvider] 로부터 파생 —
/// 키 미설정(auth == null)이면 null. 테스트는 `FakeCalendarGateway` 로 override.
final calendarGatewayProvider = Provider<CalendarGateway?>((ref) {
  final auth = ref.watch(calendarAuthProvider);
  return auth == null ? null : GoogleCalendarGateway(auth);
});

/// 사용자가 접근 가능한 캘린더 목록 — 네트워크 호출. "연결됨" 상태에서만 watch 된다.
/// autoDispose — 화면을 벗어나면 캐시를 버려, 재진입 시 항상 최신 목록을 다시 받는다.
final calendarListProvider = FutureProvider.autoDispose<List<CalendarInfo>>((
  ref,
) async {
  final gateway = ref.watch(calendarGatewayProvider);
  if (gateway == null) return const [];
  return gateway.listCalendars();
});

/// Google Calendar 동기화 대기열 길이 — `CalendarOpsDao.watchCount` 위임.
/// 이 저장소 관례: 위젯 테스트는 Drift stream 을 직접 쓰지 않고 이 provider 를
/// override 해서 값을 주입한다.
final calendarPendingOpsCountProvider = StreamProvider.autoDispose<int>((ref) {
  return ref.watch(appDatabaseProvider).calendarOpsDao.watchCount();
});

/// "지금 동기화" 버튼의 실행부.
///
/// 동기화 서비스는 다음 wave 에서 만들어진다 — 지금은 항상 null 이라 버튼이
/// 비활성화된 채로 자리만 잡는다. 다음 wave 가 이 provider 를 override 해서
/// 실제 동기화 함수를 주입하면 버튼이 그대로 살아난다 (화면 쪽 변경 불필요).
final calendarSyncNowActionProvider = Provider<Future<void> Function()?>(
  (ref) => null,
);

// ---------------------------------------------------------------------------
// 화면
// ---------------------------------------------------------------------------

/// Google Calendar 연동 설정 화면 (설정 > Google Calendar).
///
/// 3 상태:
/// - **키 없음** ([googleCalendarAvailableProvider] == false) — 안내만, 어떤
///   동작도 할 수 없다 (OAuth 클라이언트 키 자체가 없는 개발자 설정 문제).
/// - **미연결** ([CalendarSettings.connected] == false) — [Google 계정 연결]
///   버튼만 노출.
/// - **연결됨** — 쓰기 캘린더 선택 / 가져올 캘린더 + 카테고리 매핑 / 옵션 /
///   동기화 상태 전부 노출.
class CalendarSettingsScreen extends ConsumerStatefulWidget {
  const CalendarSettingsScreen({super.key});

  static Future<void> show(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CalendarSettingsScreen()));
  }

  @override
  ConsumerState<CalendarSettingsScreen> createState() =>
      _CalendarSettingsScreenState();
}

class _CalendarSettingsScreenState
    extends ConsumerState<CalendarSettingsScreen> {
  /// 연결 / 연결 해제 / 재연결 진행 중 — 버튼 잠금 공용.
  bool _connectBusy = false;

  /// "지금 동기화" 진행 중.
  bool _syncBusy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = ref.watch(googleCalendarAvailableProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Google Calendar')),
      body: !available ? _KeyMissing(theme: theme) : _buildGate(theme),
    );
  }

  Widget _buildGate(ThemeData theme) {
    final settings = ref.watch(calendarSettingsProvider);
    if (!settings.connected) {
      return _NotConnected(
        theme: theme,
        busy: _connectBusy,
        onConnect: _connect,
      );
    }
    return _connectedBody(theme, settings);
  }

  // --- 연결 / 연결 해제 --------------------------------------------------

  Future<void> _connect() async {
    final auth = ref.read(calendarAuthProvider);
    if (auth == null || _connectBusy) return;
    setState(() => _connectBusy = true);

    http.Client? client;
    try {
      client = await auth.authedClient();
    } catch (_) {
      client = null;
    } finally {
      client?.close();
    }

    if (!mounted) return;
    if (client == null) {
      setState(() => _connectBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google 계정 연결이 취소됐거나 실패했어요.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await ref
        .read(calendarSettingsProvider.notifier)
        .update((s) => s.copyWith(connected: true));
    if (mounted) setState(() => _connectBusy = false);
  }

  /// 연결 해제 — [CalendarAuth.signOut] 호출 후 연결 관련 상태만 정리한다.
  /// 쓰기/읽기 캘린더 선택과 카테고리 매핑은 [CalendarSettings.copyWith] 에
  /// 넘기지 않아 그대로 보존된다 (재연결 시 복원). 구글 이벤트와 todo 의
  /// calendarEventId 링크는 이 화면이 건드리지 않는다.
  ///
  /// 대기 중인 push 큐는 **비운다**. 연결이 끊긴 상태로 남겨두면 재연결 시점에
  /// (계정이 바뀌었을 수도 있는데) 오래된 작업이 되살아나 엉뚱한 캘린더에
  /// 재생되거나 실패만 반복한다. 재연결 후에는 그 시점 상태로 다시 시작한다.
  Future<void> _disconnect() async {
    if (_connectBusy) return;
    setState(() => _connectBusy = true);
    try {
      await ref.read(calendarAuthProvider)?.signOut();
      await ref.read(appDatabaseProvider).calendarOpsDao.clear();
    } finally {
      await ref
          .read(calendarSettingsProvider.notifier)
          .update(
            (s) => s.copyWith(
              connected: false,
              syncTokens: const {},
              clearLastSyncedAt: true,
            ),
          );
      if (mounted) setState(() => _connectBusy = false);
    }
  }

  /// 캘린더 목록 조회가 재인증 필요(authRequired) 오류를 낸 뒤 사용자가
  /// "다시 연결" 을 눌렀을 때 — 동의를 다시 받고 목록을 새로 받는다.
  Future<void> _reconnect() async {
    await _connect();
    ref.invalidate(calendarListProvider);
  }

  Future<void> _syncNow() async {
    final action = ref.read(calendarSyncNowActionProvider);
    if (action == null || _syncBusy) return;
    setState(() => _syncBusy = true);
    try {
      await action();
    } catch (_) {
      // 오류 처리는 동기화 서비스(다음 wave) 책임 — 여기선 버튼 잠금만 푼다.
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  // --- 연결됨 본문 ---------------------------------------------------------

  Widget _connectedBody(ThemeData theme, CalendarSettings settings) {
    final scheme = theme.colorScheme;
    final calendarsAsync = ref.watch(calendarListProvider);
    final categories =
        ref.watch(activeCategoriesProvider).asData?.value ?? const <Category>[];
    final pendingCount =
        ref.watch(calendarPendingOpsCountProvider).asData?.value ?? 0;
    final hPad = AppPlatform.isMobile ? AppTokens.space16 : AppTokens.space20;

    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: hPad,
        vertical: AppTokens.space16,
      ),
      children: [
        _connectionHeader(theme, scheme),
        const SizedBox(height: AppTokens.space16),
        const Divider(height: AppTokens.hairline),
        const SizedBox(height: AppTokens.space16),
        calendarsAsync.when(
          data: (calendars) =>
              _calendarSections(theme, scheme, settings, calendars, categories),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTokens.space32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (err, _) => _CalendarListError(
            theme: theme,
            authRequired:
                err is CalendarGatewayException &&
                err.kind == CalendarErrorKind.authRequired,
            busy: _connectBusy,
            onRetry: () => ref.invalidate(calendarListProvider),
            onReconnect: _reconnect,
          ),
        ),
        const SizedBox(height: AppTokens.space16),
        const Divider(height: AppTokens.hairline),
        const SizedBox(height: AppTokens.space8),
        _optionsSection(settings),
        const SizedBox(height: AppTokens.space16),
        const Divider(height: AppTokens.hairline),
        const SizedBox(height: AppTokens.space16),
        _syncFooter(theme, scheme, settings, pendingCount),
      ],
    );
  }

  /// 연결 상태 표시 줄 — 초록 점 + "연결됨" + [연결 해제] 버튼.
  ///
  /// 계정 이메일은 표시하지 않는다: [CalendarAuth] 인터페이스가 로그인 계정의
  /// 이메일을 노출하는 메서드를 갖고 있지 않다 (authedClient/signOut 뿐). 새
  /// 메서드를 material 파일에 추가하지 말라는 지시에 따라 이번 task 에선 상태만
  /// 보여준다 — 이메일 노출은 별도 task 로 보고한다.
  Widget _connectionHeader(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: Color(0xFF10B981),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppTokens.space8),
        Expanded(
          child: Text(
            '연결됨',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (_connectBusy)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          TextButton(
            key: const ValueKey('disconnect-button'),
            onPressed: _disconnect,
            child: const Text('연결 해제'),
          ),
      ],
    );
  }

  Widget _calendarSections(
    ThemeData theme,
    ColorScheme scheme,
    CalendarSettings settings,
    List<CalendarInfo> calendars,
    List<Category> categories,
  ) {
    // 읽기 전용 캘린더(공휴일 등)는 쓰기 대상에서 제외.
    final writable = calendars.where((c) => c.canWrite).toList();
    final writeValue = writable.any((c) => c.id == settings.writeCalendarId)
        ? settings.writeCalendarId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '할 일을 등록할 캘린더',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppTokens.space8),
        if (writable.isEmpty)
          Text(
            '쓰기 가능한 캘린더가 없어요.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          )
        else
          DropdownButton<String>(
            key: const ValueKey('write-calendar-dropdown'),
            isExpanded: true,
            value: writeValue,
            hint: const Text('캘린더 선택'),
            items: [
              for (final c in writable)
                DropdownMenuItem(value: c.id, child: Text(c.summary)),
            ],
            onChanged: (id) {
              if (id == null) return;
              ref
                  .read(calendarSettingsProvider.notifier)
                  .update((s) => s.copyWith(writeCalendarId: id));
            },
          ),
        const SizedBox(height: AppTokens.space20),
        Text(
          '가져올 캘린더',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppTokens.space4),
        if (calendars.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
            child: Text(
              '연결된 캘린더가 없어요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          )
        else
          for (final c in calendars)
            _readCalendarRow(theme, scheme, settings, c, categories),
      ],
    );
  }

  Widget _readCalendarRow(
    ThemeData theme,
    ColorScheme scheme,
    CalendarSettings settings,
    CalendarInfo calendar,
    List<Category> categories,
  ) {
    final checked = settings.readCalendarIds.contains(calendar.id);
    final mapped = settings.categoryMap[calendar.id];
    final fallback = settings.defaultCategoryId.isNotEmpty
        ? settings.defaultCategoryId
        : (categories.isNotEmpty ? categories.first.id : null);
    final currentCategoryId =
        (mapped != null && categories.any((cat) => cat.id == mapped))
        ? mapped
        : fallback;

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: AppPlatform.isMobile ? AppTokens.space2 : AppTokens.space4,
      ),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('read-cal-checkbox-${calendar.id}'),
            value: checked,
            visualDensity: AppPlatform.isMobile
                ? VisualDensity.compact
                : VisualDensity.standard,
            onChanged: (v) {
              final set = Set<String>.of(settings.readCalendarIds);
              if (v ?? false) {
                set.add(calendar.id);
              } else {
                set.remove(calendar.id);
              }
              ref
                  .read(calendarSettingsProvider.notifier)
                  .update((s) => s.copyWith(readCalendarIds: set.toList()));
            },
          ),
          Expanded(
            child: Text(
              calendar.summary,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: AppTokens.space8),
          if (categories.isEmpty)
            Text(
              '카테고리 없음',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            )
          else
            DropdownButton<String>(
              key: ValueKey('read-cal-category-${calendar.id}'),
              value: currentCategoryId,
              items: [
                for (final cat in categories)
                  DropdownMenuItem(value: cat.id, child: Text(cat.label)),
              ],
              onChanged: (catId) {
                if (catId == null) return;
                final map = Map<String, String>.of(settings.categoryMap)
                  ..[calendar.id] = catId;
                ref
                    .read(calendarSettingsProvider.notifier)
                    .update((s) => s.copyWith(categoryMap: map));
              },
            ),
        ],
      ),
    );
  }

  Widget _optionsSection(CalendarSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: const ValueKey('import-invited-checkbox'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: settings.importInvited,
          title: const Text('초대받은 일정도 가져오기'),
          onChanged: (v) {
            ref
                .read(calendarSettingsProvider.notifier)
                .update((s) => s.copyWith(importInvited: v ?? false));
          },
        ),
        CheckboxListTile(
          key: const ValueKey('auto-sync-checkbox'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          value: settings.autoSync,
          title: const Text('자동 동기화 (5분)'),
          onChanged: (v) {
            ref
                .read(calendarSettingsProvider.notifier)
                .update((s) => s.copyWith(autoSync: v ?? false));
          },
        ),
      ],
    );
  }

  Widget _syncFooter(
    ThemeData theme,
    ColorScheme scheme,
    CalendarSettings settings,
    int pendingCount,
  ) {
    final lastSyncedAt = settings.lastSyncedAt;
    final lastSyncedLabel = lastSyncedAt == null
        ? '동기화 기록 없음'
        : '마지막 동기화 ${KoDate.time(lastSyncedAt.toLocal())}';
    final syncAvailable = ref.watch(calendarSyncNowActionProvider) != null;

    return Row(
      children: [
        Expanded(
          child: Text(
            '$lastSyncedLabel · 대기 $pendingCount건',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        if (_syncBusy)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          TextButton(
            key: const ValueKey('sync-now-button'),
            onPressed: syncAvailable ? _syncNow : null,
            child: const Text('지금 동기화'),
          ),
      ],
    );
  }
}

class _KeyMissing extends StatelessWidget {
  const _KeyMissing({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: AppTokens.space16),
            Text(
              'Google Calendar 연동이 아직 설정되지 않았어요',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: AppTokens.space8),
            Text(
              'OAuth 클라이언트 키가 설정되면 이 화면에서 연결할 수 있어요.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotConnected extends StatelessWidget {
  const _NotConnected({
    required this.theme,
    required this.busy,
    required this.onConnect,
  });

  final ThemeData theme;
  final bool busy;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_available_outlined,
              size: 48,
              color: scheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: AppTokens.space16),
            Text(
              'Google 계정을 연결하면\n할 일을 캘린더에 자동으로 등록할 수 있어요',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: AppTokens.space20),
            FilledButton.icon(
              key: const ValueKey('connect-button'),
              onPressed: busy ? null : onConnect,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.login),
              label: const Text('Google 계정 연결'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarListError extends StatelessWidget {
  const _CalendarListError({
    required this.theme,
    required this.authRequired,
    required this.busy,
    required this.onRetry,
    required this.onReconnect,
  });

  final ThemeData theme;
  final bool authRequired;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTokens.space24),
      child: Column(
        children: [
          Icon(Icons.error_outline, size: 32, color: scheme.error),
          const SizedBox(height: AppTokens.space8),
          Text(
            authRequired ? '다시 연결이 필요해요.' : '캘린더 목록을 불러오지 못했어요.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppTokens.space12),
          TextButton(
            key: const ValueKey('calendar-list-retry'),
            onPressed: busy ? null : (authRequired ? onReconnect : onRetry),
            child: Text(authRequired ? '다시 연결' : '재시도'),
          ),
        ],
      ),
    );
  }
}
