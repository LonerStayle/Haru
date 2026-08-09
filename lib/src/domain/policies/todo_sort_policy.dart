import '../todo.dart';

/// 목록(카테고리 화면 / 하위 상세 화면)의 정렬 방식.
///
/// - [manual] — 사용자가 드래그로 정한 순서 (`sortOrder`, DAO 기본 정렬). 기본값.
/// - [dueDate] — 지정한 일정(`dueAt`)이 빠른 순. 날짜 없는 항목은 맨 뒤로 모인다.
///
/// [storageValue] 는 영속 저장(shared_preferences)용 문자열. enum 이름을 그대로 쓰지
/// 않고 명시 값으로 고정해, 나중에 enum 을 리네임해도 저장된 설정이 깨지지 않게 한다.
enum TodoSortMode {
  manual('manual'),
  dueDate('due_date');

  const TodoSortMode(this.storageValue);

  final String storageValue;

  /// 저장된 문자열에서 복원. 미지 값 / null 은 [manual] 로 안전 fallback.
  static TodoSortMode fromStorage(String? value) {
    for (final mode in TodoSortMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return TodoSortMode.manual;
  }

  /// 토글(버튼 한 번) 시 다음 모드. 현재는 수동 ↔ 일정순 2단.
  TodoSortMode get toggled =>
      this == TodoSortMode.manual ? TodoSortMode.dueDate : TodoSortMode.manual;
}

/// 목록 정렬 정책 — 화면(위젯)에서 쓰는 단일 출처.
///
/// [TodoSortMode.dueDate] 규칙:
/// - `dueAt` 이 있는 항목이 먼저, 빠른 시각부터. (기간 항목은 시작 시각 `dueAt` 기준.)
/// - `dueAt` 이 없는 항목은 전부 그 뒤로 — 그 안에서는 **원래(수동) 순서** 유지.
/// - `dueAt` 이 같은 항목끼리도 **원래 순서** 유지 (stable). Dart 의 [List.sort] 는
///   stable 을 보장하지 않으므로 원본 인덱스를 tie-break 로 명시한다.
class TodoSortPolicy {
  const TodoSortPolicy._();

  /// [items] 를 [mode] 규칙으로 정렬한 **새 리스트**를 반환. 원본은 변형하지 않는다.
  static List<Todo> apply(List<Todo> items, TodoSortMode mode) {
    if (mode == TodoSortMode.manual || items.length < 2) {
      return List<Todo>.of(items);
    }
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
    indexed.sort((a, b) {
      final ad = a.$2.dueAt;
      final bd = b.$2.dueAt;
      if (ad == null && bd == null) return a.$1.compareTo(b.$1);
      // 날짜 없는 항목은 항상 뒤로.
      if (ad == null) return 1;
      if (bd == null) return -1;
      // DateTime.compareTo 는 절대 시각(epoch) 비교라 UTC/로컬 혼재해도 안전.
      final byDue = ad.compareTo(bd);
      return byDue != 0 ? byDue : a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }
}
