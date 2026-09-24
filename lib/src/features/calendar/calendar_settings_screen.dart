import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/date_format.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../domain/category.dart';
import '../category/categories_controller.dart';
import 'calendar_event.dart';
import 'calendar_gateway.dart';
import 'calendar_settings.dart';
import 'google_auth_service.dart';
import 'google_calendar_gateway.dart';
import 'microsoft_auth_service.dart';
import 'microsoft_graph_gateway.dart';

// ---------------------------------------------------------------------------
// Providers — 이 화면과 동기화 서비스가 함께 볼 진입점들.
// ---------------------------------------------------------------------------

/// Google Calendar API 게이트웨이. [calendarAuthProvider] 로부터 파생 —
/// 키 미설정(auth == null)이면 null. 테스트는 `FakeCalendarGateway` 로 override.
final calendarGatewayProvider = Provider<CalendarGateway?>((ref) {
  final auth = ref.watch(calendarAuthProvider);
  return auth == null ? null : GoogleCalendarGateway(auth);
});

/// Microsoft Graph 게이트웨이. Azure 클라이언트 ID 가 없으면 null.
final microsoftGatewayProvider = Provider<CalendarGateway?>((ref) {
  final auth = ref.watch(microsoftAuthProvider);
  return auth == null ? null : MicrosoftGraphGateway(auth);
});

/// provider 로 게이트웨이 고르기 — 화면·동기화 조립이 공통으로 쓴다.
final gatewayForProvider = Provider.family<CalendarGateway?, CalendarProvider>((
  ref,
  provider,
) {
  return provider == CalendarProvider.microsoft
      ? ref.watch(microsoftGatewayProvider)
      : ref.watch(calendarGatewayProvider);
});

/// provider 로 인증 고르기 (연결 / 연결 해제 버튼용).
final authForProvider = Provider.family<CalendarAuth?, CalendarProvider>((
  ref,
  provider,
) {
  return provider == CalendarProvider.microsoft
      ? ref.watch(microsoftAuthProvider)
      : ref.watch(calendarAuthProvider);
});

/// 그 서비스의 연동을 사용자에게 노출할지 (OAuth 키가 빌드에 있는가).
final calendarAvailableFor = Provider.family<bool, CalendarProvider>((
  ref,
  provider,
) {
  return provider == CalendarProvider.microsoft
      ? ref.watch(microsoftCalendarAvailableProvider)
      : ref.watch(googleCalendarAvailableProvider);
});

/// 사용자가 접근 가능한 캘린더 목록 — 네트워크 호출. "연결됨" 상태에서만 watch 된다.
/// autoDispose — 화면을 벗어나면 캐시를 버려, 재진입 시 항상 최신 목록을 다시 받는다.
final calendarListProvider = FutureProvider.autoDispose
    .family<List<CalendarInfo>, CalendarProvider>((ref, provider) async {
      final gateway = ref.watch(gatewayForProvider(provider));
      if (gateway == null) return const [];
      return gateway.listCalendars();
    });

/// 캘린더 동기화 대기열 길이 — `CalendarOpsDao.watchCount` 위임.
/// 이 저장소 관례: 위젯 테스트는 Drift stream 을 직접 쓰지 않고 이 provider 를
/// override 해서 값을 주입한다.
final calendarPendingOpsCountProvider = StreamProvider.autoDispose<int>((ref) {
  return ref.watch(appDatabaseProvider).calendarOpsDao.watchCount();
});

/// "지금 동기화" 버튼의 실행부.
///
/// 동기화 서비스 쪽(`calendar_providers.dart`)이 이 provider 를 override 해서
/// 실제 동기화 함수를 주입한다 — 화면 코드는 그대로 두고 버튼만 살아난다.
final calendarSyncNowActionProvider = Provider<Future<void> Function()?>(
  (ref) => null,
);

// ---------------------------------------------------------------------------
// 화면
// ---------------------------------------------------------------------------

/// 캘린더 연동 설정 화면 (설정 > Google Calendar / Microsoft 365).
///
/// **한 화면이 두 서비스를 모두 담당한다** — [provider] 만 다르다. 구글용과
/// Microsoft 용 화면을 따로 두면 항목 하나 고칠 때마다 두 곳을 고쳐야 하고,
/// 반드시 한쪽을 빠뜨린다.
///
/// 3 상태:
/// - **키 없음** — 안내만. OAuth 클라이언트 키 자체가 없는 설정 문제다.
/// - **미연결** — [계정 연결] 버튼만 노출.
/// - **연결됨** — 쓰기 캘린더 선택 / 가져올 캘린더 + 카테고리 매핑 / 옵션 /
///   동기화 상태 전부 노출.
class CalendarSettingsScreen extends ConsumerStatefulWidget {
  const CalendarSettingsScreen({
    super.key,
    this.provider = CalendarProvider.google,
  });

  /// 이 화면이 다루는 캘린더 서비스.
  final CalendarProvider provider;

  static Future<void> show(
    BuildContext context, {
    CalendarProvider provider = CalendarProvider.google,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CalendarSettingsScreen(provider: provider),
      ),
    );
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

  CalendarProvider get _provider => widget.provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = ref.watch(calendarAvailableFor(_provider));

    return Scaffold(
      appBar: AppBar(title: Text(_provider.label)),
      body: !available
          ? _KeyMissing(theme: theme, provider: _provider)
          : _buildGate(theme),
    );
  }

  Widget _buildGate(ThemeData theme) {
    final settings = ref.watch(calendarSettingsProvider);
    if (!settings.viewFor(_provider).connected) {
      return _NotConnected(
        theme: theme,
        provider: _provider,
        busy: _connectBusy,
        onConnect: _connect,
      );
    }
    return _connectedBody(theme, settings);
  }

  // --- 연결 / 연결 해제 --------------------------------------------------

  Future<void> _connect() async {
    final auth = ref.read(authForProvider(_provider));
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
        SnackBar(
          content: Text('${_provider.label} 계정 연결이 취소됐거나 실패했어요.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await ref
        .read(calendarSettingsProvider.notifier)
        .updateConnection(_provider, (c) => c.copyWith(connected: true));
    await _seedDefaultCalendar();
    if (mounted) setState(() => _connectBusy = false);
  }

  /// 연결 직후 쓰기/읽기 캘린더가 비어 있으면 계정의 기본 캘린더로 채운다.
  ///
  /// Microsoft 는 캘린더 id 가 계정마다 다른 긴 문자열이라 기본값에 미리 넣어둘 수
  /// 없다. 비워둔 채로 두면 "연결은 했는데 아무것도 안 들어온다" 가 되므로, 목록을
  /// 한 번 받아 기본 캘린더를 골라 준다. (구글은 기본값 `primary` 가 이미 유효해
  /// 아무 일도 일어나지 않는다.)
  Future<void> _seedDefaultCalendar() async {
    final view = ref.read(calendarSettingsProvider).viewFor(_provider);
    if (view.writeCalendarId.isNotEmpty && view.readCalendarIds.isNotEmpty) {
      return;
    }
    final gateway = ref.read(gatewayForProvider(_provider));
    if (gateway == null) return;

    List<CalendarInfo> calendars;
    try {
      calendars = await gateway.listCalendars();
    } catch (_) {
      return; // 목록을 못 받아도 연결 자체는 성공이다 — 설정에서 직접 고르면 된다.
    }
    if (calendars.isEmpty) return;
    final primary = calendars.firstWhere(
      (c) => c.primary && c.canWrite,
      orElse: () => calendars.firstWhere(
        (c) => c.canWrite,
        orElse: () => calendars.first,
      ),
    );

    await ref
        .read(calendarSettingsProvider.notifier)
        .updateConnection(
          _provider,
          (c) => c.copyWith(
            writeCalendarId: c.writeCalendarId.isEmpty
                ? primary.id
                : c.writeCalendarId,
            readCalendarIds: c.readCalendarIds.isEmpty
                ? [primary.id]
                : c.readCalendarIds,
          ),
        );
  }

  /// 연결 해제 — [CalendarAuth.signOut] 호출 후 연결 관련 상태만 정리한다.
  /// 쓰기/읽기 캘린더 선택과 카테고리 매핑은 그대로 보존된다 (재연결 시 복원).
  /// 캘린더 이벤트와 todo 의 calendarEventId 링크는 이 화면이 건드리지 않는다.
  ///
  /// 대기 중인 push 큐는 **이 서비스 것만 비운다**. 연결이 끊긴 상태로 남겨두면
  /// 재연결 시점에 (계정이 바뀌었을 수도 있는데) 오래된 작업이 되살아나 엉뚱한
  /// 캘린더에 재생되거나 실패만 반복한다. 다른 서비스의 대기열은 건드리지 않는다.
  Future<void> _disconnect() async {
    if (_connectBusy) return;
    setState(() => _connectBusy = true);
    try {
      await ref.read(authForProvider(_provider))?.signOut();
      await ref
          .read(appDatabaseProvider)
          .calendarOpsDao
          .clearProvider(_provider);
    } finally {
      await ref
          .read(calendarSettingsProvider.notifier)
          .updateConnection(
            _provider,
            (c) => c.copyWith(
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
    ref.invalidate(calendarListProvider(_provider));
  }

  Future<void> _syncNow() async {
    final action = ref.read(calendarSyncNowActionProvider);
    if (action == null || _syncBusy) return;
    setState(() => _syncBusy = true);
    try {
      await action();
    } catch (_) {
      // 오류 처리는 동기화 서비스 책임 — 여기선 버튼 잠금만 푼다.
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  // --- 연결됨 본문 ---------------------------------------------------------

  Widget _connectedBody(ThemeData theme, CalendarSettings settings) {
    final scheme = theme.colorScheme;
    final calendarsAsync = ref.watch(calendarListProvider(_provider));
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
            onRetry: () => ref.invalidate(calendarListProvider(_provider)),
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
  /// 이메일을 노출하는 메서드를 갖고 있지 않다 (authedClient/signOut 뿐).
  Widget _connectionHeader(ThemeData theme, ColorScheme scheme) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: AppPalette.success,
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
    final view = settings.viewFor(_provider);
    // 읽기 전용 캘린더(공휴일 등)는 쓰기 대상에서 제외.
    final writable = calendars.where((c) => c.canWrite).toList();
    final writeValue = writable.any((c) => c.id == view.writeCalendarId)
        ? view.writeCalendarId
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
                  .updateConnection(
                    _provider,
                    (c) => c.copyWith(writeCalendarId: id),
                  );
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
        _defaultProviderRow(theme, scheme, settings),
      ],
    );
  }

  /// 새 할 일을 어느 서비스에 올릴지. 두 서비스를 동시에 연결했을 때만 의미가 있어
  /// 그때만 노출한다 — 한쪽만 켠 대표님에게 고민거리를 만들지 않는다.
  Widget _defaultProviderRow(
    ThemeData theme,
    ColorScheme scheme,
    CalendarSettings settings,
  ) {
    final connected = CalendarProvider.values
        .where((p) => settings.viewFor(p).connected)
        .toList();
    // 항목이 없을 때는 여백까지 통째로 사라져야 한다 — 안 그러면 아래 내용이
    // 이유 없이 밀려 내려간다.
    if (connected.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: AppTokens.space20),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '새 할 일을 올릴 캘린더',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          DropdownButton<CalendarProvider>(
            key: const ValueKey('default-provider-dropdown'),
            value: settings.defaultProvider,
            items: [
              for (final p in connected)
                DropdownMenuItem(value: p, child: Text(p.label)),
            ],
            onChanged: (p) {
              if (p == null) return;
              ref
                  .read(calendarSettingsProvider.notifier)
                  .update((s) => s.copyWith(defaultProvider: p));
            },
          ),
        ],
      ),
    );
  }

  Widget _readCalendarRow(
    ThemeData theme,
    ColorScheme scheme,
    CalendarSettings settings,
    CalendarInfo calendar,
    List<Category> categories,
  ) {
    final view = settings.viewFor(_provider);
    final checked = view.readCalendarIds.contains(calendar.id);
    final mapped = view.categoryMap[calendar.id];
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
              final set = Set<String>.of(view.readCalendarIds);
              if (v ?? false) {
                set.add(calendar.id);
              } else {
                set.remove(calendar.id);
              }
              ref
                  .read(calendarSettingsProvider.notifier)
                  .updateConnection(
                    _provider,
                    (c) => c.copyWith(readCalendarIds: set.toList()),
                  );
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
                final map = Map<String, String>.of(view.categoryMap)
                  ..[calendar.id] = catId;
                ref
                    .read(calendarSettingsProvider.notifier)
                    .updateConnection(
                      _provider,
                      (c) => c.copyWith(categoryMap: map),
                    );
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
    final lastSyncedAt = settings.viewFor(_provider).lastSyncedAt;
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
  const _KeyMissing({required this.theme, required this.provider});
  final ThemeData theme;
  final CalendarProvider provider;

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
              '${provider.label} 연동이 아직 설정되지 않았어요',
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
    required this.provider,
    required this.busy,
    required this.onConnect,
  });

  final ThemeData theme;
  final CalendarProvider provider;
  final bool busy;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final account = provider == CalendarProvider.microsoft
        ? 'Microsoft 회사 계정'
        : 'Google 계정';
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
              '$account을 연결하면\n할 일을 캘린더에 자동으로 등록할 수 있어요',
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
              label: Text('$account 연결'),
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
