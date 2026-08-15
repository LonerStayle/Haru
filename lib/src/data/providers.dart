import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/auth_providers.dart';
import '../features/calendar/calendar_settings.dart';
import 'calendar_aware_todo_repository.dart';
import 'categories_repository.dart';
import 'groups_repository.dart';
import 'local/app_database.dart';
import 'local/local_categories_repository.dart';
import 'local/local_groups_repository.dart';
import 'local/local_todo_repository.dart';
import 'remote/supabase_categories_api.dart';
import 'remote/supabase_groups_api.dart';
import 'remote/supabase_todos_api.dart';
import 'syncing_categories_repository.dart';
import 'syncing_groups_repository.dart';
import 'syncing_todo_repository.dart';
import 'todo_repository.dart';

/// 앱 전역에서 단일 인스턴스로 유지되는 SQLite [AppDatabase].
///
/// 테스트에서는 `appDatabaseProvider.overrideWithValue(AppDatabase.memory())` 로
/// in-memory 인스턴스로 교체한다.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

/// [TodoRepository] — Supabase enabled + 인증된 user 가 있으면 [SyncingTodoRepository]
/// (local + outbox + remote push), 아니면 [LocalTodoRepository] (local only).
final todoRepositoryProvider = Provider<TodoRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(supabaseTodosApiProvider);

  final base = api == null
      ? LocalTodoRepository(db.todosDao)
      : SyncingTodoRepository(
          local: db.todosDao,
          outbox: db.outboxDao,
          api: api,
          // userIdGetter 가 호출 시점마다 ref.read 로 현재 user 반환 — sign-in/out 동적 추적.
          userIdGetter: () => ref.read(currentUserProvider)?.id,
        );

  // Google Calendar 연동이 켜져 있을 때만 캘린더 데코레이터를 한 겹 씌운다.
  // **꺼져 있으면 아예 끼우지 않는다** — 연동 없이도 앱이 이전과 완전히 동일하게
  // 동작한다는 것을 조립 단계에서 보장한다 (판정 함수에 의존하지 않는다).
  //
  // 주의: 동기화 서비스 자신은 이 provider 를 쓰면 안 된다. 수신 결과를 여기에
  // 쓰면 다시 캘린더 큐에 쌓여 되쏘게 된다 — `calendarSyncRepositoryProvider` 참고.
  final calendarConnected = ref.watch(
    calendarSettingsProvider.select((s) => s.connected),
  );
  if (!calendarConnected) return base;

  return CalendarAwareTodoRepository(
    inner: base,
    ops: db.calendarOpsDao,
    settings: () => ref.read(calendarSettingsProvider),
  );
});

/// 현재 시각을 주입 가능하게 — 테스트에서 결정성 보장 + 자정 트리거 갱신 대응.
///
/// `DateTime Function()` 형태이므로 호출자가 `()` 로 그 순간의 instant 를 가져온다.
/// **각 호출 시점마다 다른 ms 값이 반환된다** — 의도된 lazy 동작.
///   - mutation (updatedAt 등): 정확한 wall-clock 이 필요하므로 호출 시점 ms 사용 OK.
///   - 단일 frame UI: 호출자가 한 번만 `()` 호출하고 propagate (예: HomeScreen 의 now 를
///     _Header / _Loaded 에 전달) — 동일 frame 안 일관성 보장.
///
/// `Provider<DateTime>` 형태로 frame-scoped now 를 제공하지 않는 이유 — Riverpod Provider
/// 는 lazy + cached 라 자동 invalidate 가 없어 진짜 "frame 마다 fresh" 표현이 어렵다.
/// 현재 callable 형태가 mutation/UI 양쪽 요구를 단순히 충족시키는 합리적 절충.
final nowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// outbox 의 pending entry 수 stream. UI 의 "동기화 대기 N건" indicator 가 watch.
/// count == 0 이면 모두 push 완료 (또는 미인증 → 큐 비어 있음).
final outboxCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.outboxDao.watchCount();
});

/// [CategoriesRepository] — Supabase enabled + 인증 user 있으면 [SyncingCategoriesRepository]
/// (local + outbox + remote push), 아니면 [LocalCategoriesRepository] (local only).
/// todos 의 [todoRepositoryProvider] 와 동일 패턴.
final categoriesRepositoryProvider = Provider<CategoriesRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(supabaseCategoriesApiProvider);

  if (api == null) {
    return LocalCategoriesRepository(db.categoriesDao);
  }
  return SyncingCategoriesRepository(
    local: db.categoriesDao,
    outbox: db.outboxDao,
    api: api,
    userIdGetter: () => ref.read(currentUserProvider)?.id,
  );
});

/// [GroupsRepository] — Supabase enabled + 인증 user 있으면 [SyncingGroupsRepository]
/// (local + outbox + remote push), 아니면 [LocalGroupsRepository] (local only).
/// categories 의 [categoriesRepositoryProvider] 와 동일 패턴.
final groupsRepositoryProvider = Provider<GroupsRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(supabaseGroupsApiProvider);

  if (api == null) {
    return LocalGroupsRepository(db.groupsDao);
  }
  return SyncingGroupsRepository(
    local: db.groupsDao,
    outbox: db.outboxDao,
    api: api,
    userIdGetter: () => ref.read(currentUserProvider)?.id,
  );
});
