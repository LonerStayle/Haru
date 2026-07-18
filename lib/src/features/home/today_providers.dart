import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/day_boundary_provider.dart';
import '../../data/providers.dart';
import '../../domain/policies/carryover_policy.dart';
import '../../domain/policies/recurrence_dedup_policy.dart';
import '../../domain/recurrence_materializer.dart';
import '../../domain/todo.dart';
import '../category/categories_controller.dart';
import '../outline/tree_providers.dart';

/// 오늘 화면에 보일 todos (visibility 적용된 list).
///
/// [currentDayProvider] 를 watch 해 자정마다 자동 re-subscribe → 새 now() 기준 필터
/// (= 미체크 자동 이월 + 어제 체크된 항목 자동 hide 가 자정에 발화).
final watchTodayTodosProvider = StreamProvider<List<Todo>>((ref) {
  ref.watch(currentDayProvider);
  final repo = ref.watch(todoRepositoryProvider);
  final now = ref.watch(nowProvider);
  return repo.watchToday(now);
});

/// 오늘 화면에서 **보관된 카테고리의 할 일을 제외**한 목록 (오늘/카운트의 표시용 출처).
///
/// [watchTodayTodosProvider] (순수 stream) 를 그대로 두고 파생 [Provider] 에서 필터만
/// 얹는다 — StreamProvider 를 직접 건드리면 보관 집합 변화마다 stream 이 재구독돼
/// fakeAsync 기반 테스트가 정착하지 못한다. 보관 집합이 비면 원본과 동일.
final visibleTodayTodosProvider = Provider<AsyncValue<List<Todo>>>((ref) {
  final async = ref.watch(watchTodayTodosProvider);
  final archivedIds = ref.watch(archivedCategoryIdsProvider);
  if (archivedIds.isEmpty) return async;
  return async.whenData(
    (todos) =>
        todos.where((t) => !archivedIds.contains(t.category.id)).toList(),
  );
});

/// 오늘 화면 visible todos 중 미체크 항목의 개수 (트레이 카운트 표시용).
///
/// note(메모) 는 체크 개념이 없어(isDone 항상 false) 카운트에서 제외 — task 만 센다.
final undoneTodayCountProvider = Provider<int>((ref) {
  final asyncTodos = ref.watch(visibleTodayTodosProvider);
  return asyncTodos.maybeWhen(
    data: (todos) =>
        todos.where((t) => t.type == TodoType.task && !t.isDone).length,
    orElse: () => 0,
  );
});

/// 어제 이전에서 이월된 미체크 항목의 개수 (배너 표시용).
final carryoverCountProvider = Provider<int>((ref) {
  // currentDayProvider 가 자정 갱신 시 같이 재계산되도록 transitively 의존.
  // visibleTodayTodosProvider 가 이미 watch 하므로 별도 watch 불필요.
  final asyncTodos = ref.watch(visibleTodayTodosProvider);
  final nowFn = ref.watch(nowProvider);
  return asyncTodos.maybeWhen(
    data: (todos) {
      final now = nowFn();
      return todos
          .where((t) => CarryoverPolicy.shouldCarryOverToday(t, now))
          .length;
    },
    orElse: () => 0,
  );
});

/// date-repeat — 반복 인스턴스 lazy 생성 트리거.
///
/// 전체 todos 를 구독해, 활성 반복 마스터의 누락 발생분(anchor~오늘)을 생성·upsert 한다.
/// [currentDayProvider] 를 watch 하므로 **앱 시작 + 자정 롤오버**마다 재평가된다.
///
/// 멱등: [RecurrenceMaterializer] 가 `(seriesId,발생일)` 중복을 가드하므로, upsert 후
/// watchAll 재emit 되어도 새로 만들 게 없으면 멈춘다. 진행 중 재진입은 [busy] 가드로 차단.
///
/// 이 provider 는 **lazy** — HomeScreen 이 watch 해야 활성화된다(앱 메인 화면 동안 동작).
final recurrenceMaterializerProvider = Provider<void>((ref) {
  ref.watch(currentDayProvider);
  final repo = ref.watch(todoRepositoryProvider);
  final nowFn = ref.watch(nowProvider);

  var busy = false;
  final sub = repo.watchAll().listen((all) async {
    if (busy) return;
    final masters = RecurrenceMaterializer.activeMasters(all);
    if (masters.isEmpty) return;
    busy = true;
    try {
      final existing = RecurrenceMaterializer.indexExistingInstanceDates(all);
      final fresh = RecurrenceMaterializer.materializeDue(
        masters,
        existing,
        nowFn(),
      );
      for (final inst in fresh) {
        await repo.upsert(inst);
      }
    } finally {
      busy = false;
    }
  });
  ref.onDispose(sub.cancel);
});

/// date-repeat — 활성 반복 마스터 목록 (반복 관리 화면용).
///
/// 마스터는 [VisibilityPolicy] 로 모든 일반 목록에서 숨겨지므로, 규칙 조회/해제는
/// 이 provider 를 통해서만 접근한다(FR-6). dueAt(anchor) 오름차순.
final recurringMastersProvider = Provider<List<Todo>>((ref) {
  final all = ref.watch(allTodosProvider).asData?.value ?? const <Todo>[];
  final masters = all.where((t) => t.isRecurringMaster).toList()
    ..sort((a, b) {
      final ad = a.dueAt, bd = b.dueAt;
      if (ad != null && bd != null) return ad.compareTo(bd);
      return a.createdAt.compareTo(b.createdAt);
    });
  return masters;
});

/// date-repeat — 오늘 화면용 dedup 결과 (FR-4).
///
/// [watchTodayTodosProvider] 의 visible 목록에 [RecurrenceDedupPolicy] 를 적용해,
/// 같은 반복 시리즈의 미체크 누적을 1건(leader)으로 접고 숨김 건수를 함께 제공한다.
/// 로딩/에러 시 빈 결과.
final dedupedTodayProvider = Provider<DedupedToday>((ref) {
  final asyncTodos = ref.watch(visibleTodayTodosProvider);
  return asyncTodos.maybeWhen(
    data: RecurrenceDedupPolicy.dedupe,
    orElse: () => const DedupedToday(visible: [], hiddenCountBySeries: {}),
  );
});
