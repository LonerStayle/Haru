import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/category.dart';
import '../../../domain/todo.dart';
import '../ai_call.dart';
import '../ai_gateway.dart';
import '../ai_json.dart';
import '../ai_todo_payload.dart';

/// T3 — 오래된 할 일마다 고르는 제안 하나.
///
/// 삭제·합치기는 일부러 없다 — 되돌리기 어렵거나 판단이 사람 몫인 동작은 제안하지 않는다.
enum AiStaleAction {
  done,
  nextWeek,
  nextMonth,
  longterm,
  keep;

  static AiStaleAction? fromName(Object? raw) {
    for (final a in values) {
      if (a.name == raw) return a;
    }
    return null;
  }
}

class AiStaleSuggestion {
  const AiStaleSuggestion(this.action, this.reason);

  final AiStaleAction action;

  /// 항목 내용에 근거한 한 줄 (40자 이내). 비어 있을 수 있다.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is AiStaleSuggestion &&
      other.action == action &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(action, reason);

  @override
  String toString() => 'AiStaleSuggestion($action, $reason)';
}

/// 오래된 할 일 정리 제안 — 제안만 하고 아무것도 바꾸지 않는다.
class AiStaleAdvisor {
  const AiStaleAdvisor();

  /// 한 번에 보내는 항목 수. 넘으면 나눠서 순차 호출한다.
  static const batchSize = 40;

  static const instructions = '''
너는 1인 개발자의 오래된 할 일 정리 도우미다. 한 달 넘게 남아 있는 할 일마다 제안 하나를 고른다.
- done: 제목·설명에 끝난 흔적이 있거나, 날짜가 이미 지난 일회성 일이라 끝났을 가능성이 높다.
- nextWeek: 곧 해야 하지만 지금 바로는 아닌 일.
- nextMonth: 미뤄도 되는 일.
- longterm: 당장 할 일이 아니라 장기 목표 성격이다(학습, 큰 개선, 언젠가 할 일).
- keep: 판단할 근거가 부족하다.
근거가 약하면 keep 을 고른다. 입력의 모든 n 에 정확히 하나씩 답한다.
reason 은 항목 내용에 근거한 한국어 한 줄, 25자 이내.
입력 항목의 키: n 번호, t 제목, c 카테고리, d 날짜, age 만든 지 며칠, kids 하위 할 일 수, desc 설명 앞부분.
출력은 JSON 하나.''';

  static const schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['suggestions'],
    'properties': {
      'suggestions': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['n', 'action', 'reason'],
          'properties': {
            'n': {'type': 'integer'},
            'action': {
              'type': 'string',
              'enum': ['done', 'nextWeek', 'nextMonth', 'longterm', 'keep'],
            },
            'reason': {'type': 'string'},
          },
        },
      },
    },
  };

  /// [items] 를 [batchSize] 씩 순서대로 보내고, 묶음마다 결과를 낸다(실패한 묶음은 null).
  /// 키는 todo id. 화면은 오는 대로 칩을 띄우고, 구독을 끊으면 남은 묶음은 보내지 않는다.
  ///
  /// [longtermAvailable] 이 false 면(장기 목표 카테고리가 지워졌거나 보관됨) longterm
  /// 제안은 keep 으로 내린다. 이미 장기 목표에 있는 항목도 마찬가지.
  Stream<Map<String, AiStaleSuggestion>?> suggest(
    AiGateway gateway,
    List<Todo> items, {
    required DateTime now,
    required bool sendDescription,
    Map<String, int> childCounts = const {},
    Set<String> archivedCategoryIds = const {},
    bool longtermAvailable = true,
  }) async* {
    for (var i = 0; i < items.length; i += batchSize) {
      final batch = items.sublist(i, math.min(i + batchSize, items.length));
      final payload = AiTodoPayload.build(
        batch,
        now: now,
        sendDescription: sendDescription,
        archivedCategoryIds: archivedCategoryIds,
        childCounts: childCounts,
        includeAge: true,
      );
      if (payload.isEmpty) continue;
      final inLongterm = {
        for (final t in batch)
          if (t.category.id == Category.longterm.id) t.id,
      };
      yield await aiJson(
        gateway,
        instructions: instructions,
        input: jsonEncode({'today': AiJson.today(now), 'items': payload.items}),
        schema: schema,
        parse: (json) => parseStaleSuggestions(
          json,
          payload.nToId,
          demoteLongterm: (id) => !longtermAvailable || inLongterm.contains(id),
        ),
      );
    }
  }
}

/// 응답 → todo id 별 제안. 최상위 모양이 틀리면 null.
///
/// 보낸 적 없는 n·같은 n 의 두 번째 답·목록 밖 action 은 버린다. [demoteLongterm] 이
/// true 인 항목의 longterm 은 keep 으로 내린다.
Map<String, AiStaleSuggestion>? parseStaleSuggestions(
  Map<String, dynamic> json,
  Map<int, String> nToId, {
  bool Function(String id)? demoteLongterm,
}) {
  final raw = json['suggestions'];
  if (raw is! List) return null;
  final out = <String, AiStaleSuggestion>{};
  for (final o in AiJson.objects(raw)) {
    final n = AiJson.integer(o['n']);
    final id = n == null ? null : nToId[n];
    if (id == null || out.containsKey(id)) continue;
    var action = AiStaleAction.fromName(o['action']);
    if (action == null) continue;
    if (action == AiStaleAction.longterm &&
        (demoteLongterm?.call(id) ?? false)) {
      action = AiStaleAction.keep;
    }
    out[id] = AiStaleSuggestion(
      action,
      AiJson.text(o['reason'], max: 40) ?? '',
    );
  }
  return out;
}

final aiStaleAdvisorProvider = Provider<AiStaleAdvisor>(
  (ref) => const AiStaleAdvisor(),
);
