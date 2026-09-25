import '../todo.dart';

/// "오래된 할 일" — 오래 손대지 못하고 남아 있는 백로그 선별 규칙 (2026-09-25).
///
/// 대표님은 날짜 없는 카테고리 백로그 중심으로 쓰고(미완료 task 대부분이 날짜 없음),
/// 한 달 넘게 남은 항목이 쌓여도 드러나는 곳이 없었다. 날짜 기반 '이월'과 달리 이건
/// **만든 지 오래된** 할 일이다.
///
/// 대상: 미완료 **최상위** 할 일(task) 중 만든 지 [days]일이 지난 것.
/// 제외: 메모, 하위 항목(부모와 함께 다룬다), 반복 마스터·회차, 보관된 카테고리
/// ([activeCategoryIds] 밖), 오늘 이후로 날짜가 잡힌 것(이미 계획된 일).
/// 순서: 오래된 순(createdAt 오름차순), 같으면 id.
class StaleBacklogPolicy {
  const StaleBacklogPolicy._();

  static const defaultDays = 30;

  static List<Todo> select(
    List<Todo> all, {
    required Set<String> activeCategoryIds,
    required DateTime now,
    int days = defaultDays,
  }) {
    final cutoff = now.subtract(Duration(days: days));
    final todayStart = DateTime(now.year, now.month, now.day);
    final result = [
      for (final t in all)
        if (t.type == TodoType.task &&
            !t.isDone &&
            t.parentId == null &&
            !t.isSeriesMaster &&
            t.seriesId == null &&
            activeCategoryIds.contains(t.category.id) &&
            !t.createdAt.isAfter(cutoff) &&
            (t.dueAt == null || t.dueAt!.toLocal().isBefore(todayStart)))
          t,
    ];
    result.sort((a, b) {
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return result;
  }

  /// 만든 지 며칠 됐는지(로컬 날짜 기준).
  static int ageInDays(Todo t, DateTime now) {
    final c = t.createdAt.toLocal();
    final start = DateTime(c.year, c.month, c.day);
    final today = DateTime(now.year, now.month, now.day);
    return today.difference(start).inDays;
  }
}
