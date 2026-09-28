import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/calendar_aware_todo_repository.dart';
import '../../data/local/local_todo_repository.dart';
import '../../data/providers.dart';
import '../../data/remote/supabase_todos_api.dart';
import '../../data/syncing_todo_repository.dart';
import '../../data/todo_repository.dart';
import '../auth/auth_providers.dart';
import '../category/categories_controller.dart';
import 'calendar_event.dart';
import 'calendar_settings.dart';
import 'calendar_settings_screen.dart';
import 'calendar_sync_coordinator.dart';
import 'calendar_sync_scheduler.dart';
import 'calendar_sync_service.dart';

/// 동기화 서비스가 쓰는 **캘린더 데코레이터 없는** 저장소.
///
/// 이게 이 파일에서 가장 중요한 구분이다. 수신 결과를 데코레이터가 씌워진 저장소에
/// 쓰면 그 저장이 다시 캘린더 큐에 쌓여 방금 받아온 것을 되쏘게 된다. 기존
/// `SupabaseRealtimeSync` 가 같은 이유로 outbox 를 우회해 로컬 저장소를 직접 쓰는
/// 것과 정확히 같은 문제다.
///
/// Supabase 전파는 필요하므로 (다른 기기도 유입 결과를 봐야 한다) `Syncing` 계층은
/// 그대로 두고 캘린더 데코레이터만 벗긴다.
final calendarSyncRepositoryProvider = Provider<TodoRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(supabaseTodosApiProvider);
  if (api == null) return LocalTodoRepository(db.todosDao);
  return SyncingTodoRepository(
    local: db.todosDao,
    outbox: db.outboxDao,
    api: api,
    userIdGetter: () => ref.read(currentUserProvider)?.id,
  );
});

/// 서비스별 push/pull 실행부. 게이트웨이가 없으면(키 미설정) null.
final calendarSyncServiceFor =
    Provider.family<CalendarSyncService?, CalendarProvider>((ref, provider) {
      final gateway = ref.watch(gatewayForProvider(provider));
      if (gateway == null) return null;
      return CalendarSyncService(
        gateway: gateway,
        ops: ref.watch(appDatabaseProvider).calendarOpsDao,
        repo: ref.watch(calendarSyncRepositoryProvider),
      );
    });

/// 구글 실행부 — 기존 호출부/테스트 호환용 별칭.
final calendarSyncServiceProvider = Provider<CalendarSyncService?>(
  (ref) => ref.watch(calendarSyncServiceFor(CalendarProvider.google)),
);

/// 서비스별 push→pull 오케스트레이터.
final calendarSyncCoordinatorFor =
    Provider.family<CalendarSyncCoordinator?, CalendarProvider>((
      ref,
      provider,
    ) {
      final service = ref.watch(calendarSyncServiceFor(provider));
      if (service == null) return null;
      return CalendarSyncCoordinator(
        service: service,
        preference: ref.watch(calendarSettingsPreferenceProvider),
        readSettings: () => ref.read(calendarSettingsProvider),
        writeSettings: (s) =>
            ref.read(calendarSettingsProvider.notifier).update((_) => s),
        activeCategories: () =>
            ref.read(activeCategoriesProvider).asData?.value ?? const [],
      );
    });

/// 연결 가능한 모든 서비스의 코디네이터. 키가 없는 서비스는 애초에 빠진다.
final calendarSyncCoordinatorsProvider =
    Provider<List<CalendarSyncCoordinator>>(
      (ref) => [
        for (final p in CalendarProvider.values)
          ?ref.watch(calendarSyncCoordinatorFor(p)),
      ],
    );

/// 자동 동기화 스케줄러. `AppShell` 이 watch 해서 살아있게 한다.
/// 코디네이터가 하나도 없으면(키 미설정) null — 스케줄러를 띄울 이유가 없다.
final calendarSyncSchedulerProvider = Provider<CalendarSyncScheduler?>((ref) {
  final coordinators = ref.watch(calendarSyncCoordinatorsProvider);
  if (coordinators.isEmpty) return null;
  final scheduler = CalendarSyncScheduler(
    coordinators: coordinators,
    autoSyncEnabled: () => ref.read(calendarSettingsProvider).autoSync,
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

/// "이번 저장은 캘린더에 등록할지" 를 데코레이터에 알린다.
///
/// 편집 시트의 토글이 저장 직전에 호출한다. 설정 기본값만으로는 "이 항목만
/// 올리지 않기" 를 표현할 수 없어서 필요하다. 연동이 꺼져 있으면 아무 일도 하지
/// 않는다 — 호출자가 연동 여부를 신경 쓰지 않아도 되게.
final calendarIntentProvider = Provider<void Function(bool)>((ref) {
  final repo = ref.read(todoRepositoryProvider);
  if (repo is CalendarAwareTodoRepository) return repo.intendCalendar;
  return (_) {};
});

/// 설정 화면의 "지금 동기화" 버튼이 쓰는 실행부.
///
/// 화면 코드는 그대로 두고 이 override 만으로 버튼이 살아난다.
/// 연결된 **모든** 서비스를 한 번에 돌린다.
final calendarSyncNowOverride = calendarSyncNowActionProvider.overrideWith((
  ref,
) {
  final scheduler = ref.watch(calendarSyncSchedulerProvider);
  if (scheduler == null) return null;
  return scheduler.syncNow;
});
