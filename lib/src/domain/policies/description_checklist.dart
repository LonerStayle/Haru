/// 설명 속 목록 줄 → 하위 항목 변환 규칙.
///
/// 대표님은 큰 일을 하위 항목 대신 **설명에 목록으로** 적는 경우가 많다(2026-09 실사용
/// 기준 목록형 설명 58건, 하위 항목을 쓴 부모는 8개). 이미 적어 둔 그 목록을 체크 가능한
/// 하위 항목으로 옮겨 주는 게 이 규칙의 목적이다.
///
/// 목록 줄로 보는 것: `- ` `* ` `• ` `· ` `1. ` `1) ` 로 시작하거나 체크박스(`[ ]` `[x]`,
/// 앞에 `- ` 가 붙어도 됨)로 시작하는 줄. 들여쓴 하위 목록도 한 단계로 펼친다.
/// 목록이 아닌 줄(문단·제목)은 설명에 그대로 남긴다.
class DescriptionChecklist {
  const DescriptionChecklist._({required this.items, required this.remaining});

  /// 목록 줄에서 뽑은 하위 항목 후보(입력 순서).
  final List<ChecklistItem> items;

  /// 목록 줄을 뺀 나머지 설명. 비면 null.
  final String? remaining;

  bool get isEmpty => items.isEmpty;

  static final _marker = RegExp(
    r'^\s*(?:(?:[-*•·]|\d{1,3}[.)])\s+)?(?:\[( |x|X)\]\s*)?',
  );
  static final _bullet = RegExp(r'^\s*(?:[-*•·]|\d{1,3}[.)])\s+\S');
  static final _checkbox = RegExp(r'^\s*(?:[-*]\s+)?\[( |x|X)\]\s*\S');

  static DescriptionChecklist parse(String? description) {
    if (description == null || description.trim().isEmpty) {
      return const DescriptionChecklist._(items: [], remaining: null);
    }
    final items = <ChecklistItem>[];
    final kept = <String>[];
    for (final line in description.split('\n')) {
      if (_bullet.hasMatch(line) || _checkbox.hasMatch(line)) {
        final m = _marker.firstMatch(line)!;
        final title = cleanTitle(line.substring(m.end));
        if (title.isEmpty) continue;
        final box = m.group(1);
        items.add(ChecklistItem(title, done: box == 'x' || box == 'X'));
      } else {
        kept.add(line);
      }
    }
    if (items.isEmpty) {
      return DescriptionChecklist._(items: const [], remaining: description);
    }
    // 목록이 빠진 자리의 빈 줄이 겹치지 않게 정리한다.
    final collapsed = <String>[];
    for (final l in kept) {
      final blank = l.trim().isEmpty;
      if (blank && (collapsed.isEmpty || collapsed.last.trim().isEmpty)) {
        continue;
      }
      collapsed.add(l);
    }
    while (collapsed.isNotEmpty && collapsed.last.trim().isEmpty) {
      collapsed.removeLast();
    }
    final rest = collapsed.join('\n').trim();
    return DescriptionChecklist._(
      items: List.unmodifiable(items),
      remaining: rest.isEmpty ? null : rest,
    );
  }

  static final _bold = RegExp(r'(\*\*|__)(.+?)\1');
  static final _code = RegExp(r'`([^`]+)`');

  /// 제목에 남은 마크다운 강조 기호(`**굵게**`, `__굵게__`, `` `코드` ``)를 벗긴다.
  static String cleanTitle(String raw) => raw
      .replaceAllMapped(_bold, (m) => m.group(2)!)
      .replaceAllMapped(_code, (m) => m.group(1)!)
      .trim();

  /// 붙여넣은 한 줄에서 목록 기호·체크박스·강조 기호를 벗긴다 — 여러 줄 붙여넣기용.
  static String stripListLine(String line) {
    final m = _marker.firstMatch(line);
    return cleanTitle(m == null ? line : line.substring(m.end));
  }
}

class ChecklistItem {
  const ChecklistItem(this.title, {this.done = false});

  final String title;
  final bool done;

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem && other.title == title && other.done == done;

  @override
  int get hashCode => Object.hash(title, done);

  @override
  String toString() => 'ChecklistItem($title, done: $done)';
}
