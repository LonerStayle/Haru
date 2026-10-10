import 'chatgpt_errors.dart';

/// 응답 하나의 끝 상태.
sealed class ResponseOutcome {
  const ResponseOutcome(this.id, this.items);

  final String? id;

  /// 확정된 output item 들 (정답 원천).
  final List<Map<String, dynamic>> items;

  /// message item 의 output_text 를 순서대로 이은 것. refusal 은 `(응답 거부) …`.
  String get text {
    final sb = StringBuffer();
    for (final item in items) {
      if (item['type'] != 'message') continue;
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is! Map) continue;
        if (part['type'] == 'output_text' && part['text'] is String) {
          sb.write(part['text']);
        } else if (part['type'] == 'refusal' && part['refusal'] is String) {
          sb.write('(응답 거부) ${part['refusal']}');
        }
      }
    }
    return sb.toString();
  }

  bool get hasRefusal => items.any((item) {
    final content = item['content'];
    return item['type'] == 'message' &&
        content is List &&
        content.any((p) => p is Map && p['type'] == 'refusal');
  });
}

class ResponseCompleted extends ResponseOutcome {
  const ResponseCompleted(super.id, super.items);
}

class ResponseIncomplete extends ResponseOutcome {
  const ResponseIncomplete(super.id, super.items, this.reason);

  final String? reason;
}

/// SSE 이벤트 → 결과 (사양서 A.13 이벤트 표).
class ResponsesAccumulator {
  ResponsesAccumulator({this.onTextDelta});

  final void Function(String delta)? onTextDelta;

  String? _id;
  final _done = <int, Map<String, dynamic>>{};
  int? _lastSeq;
  ResponseOutcome? _outcome;

  bool get isTerminal => _outcome != null;

  /// 터미널 이벤트면 true. `response.failed` / `error` 는 분류해 throw.
  bool accept(Map<String, dynamic> event) {
    if (_outcome != null) return true;
    final seq = event['sequence_number'];
    if (seq is int) {
      final last = _lastSeq;
      if (last != null && seq <= last) return false;
      _lastSeq = seq;
    }
    final response = event['response'];
    switch (event['type']) {
      case 'response.created':
      case 'response.queued':
      case 'response.in_progress':
        if (response is Map && response['id'] is String) {
          _id = response['id'] as String;
        }
      case 'response.output_text.delta':
        final delta = event['delta'];
        if (delta is String && delta.isNotEmpty) onTextDelta?.call(delta);
      case 'response.output_item.done':
        final index = event['output_index'];
        final item = event['item'];
        if (index is int && item is Map<String, dynamic>) _done[index] = item;
      case 'response.completed':
        _outcome = ResponseCompleted(_idOf(response), _finalItems(response));
        return true;
      case 'response.incomplete':
        final details = response is Map ? response['incomplete_details'] : null;
        final reason = details is Map ? details['reason'] : null;
        _outcome = ResponseIncomplete(
          _idOf(response),
          _finalItems(response),
          reason is String ? reason : null,
        );
        return true;
      case 'response.failed':
        final err = response is Map ? response['error'] : null;
        throw classifyStreamError(
          type: _s(err, 'type'),
          code: _s(err, 'code'),
          param: _s(err, 'param'),
          message: _s(err, 'message'),
        );
      case 'error':
        final nested = event['error'];
        final src = nested is Map ? nested : event;
        final type = _s(src, 'type');
        throw classifyStreamError(
          type: type == 'error' ? null : type,
          code: _s(src, 'code'),
          param: _s(src, 'param'),
          message: _s(src, 'message'),
        );
    }
    return false;
  }

  /// 터미널 없이 끝났으면 [networkError] (재시도 대상).
  ResponseOutcome finish() => _outcome ?? (throw networkError);

  String? _idOf(Object? response) => response is Map && response['id'] is String
      ? response['id'] as String
      : _id;

  List<Map<String, dynamic>> _finalItems(Object? response) {
    final keys = _done.keys.toList()..sort();
    final done = [for (final k in keys) _done[k]!];
    final output = response is Map ? response['output'] : null;
    if (output is List && output.isNotEmpty) {
      final items = output.whereType<Map<String, dynamic>>().toList();
      String sig(Map<String, dynamic> i) =>
          '${i['type']}|${i['id']}|${i['call_id']}';
      final same =
          items.length == done.length &&
          List.generate(
            items.length,
            (i) => sig(items[i]) == sig(done[i]),
          ).every((x) => x);
      if (!same) return items;
    }
    return done;
  }
}

String? _s(Object? map, String key) {
  if (map is! Map) return null;
  final v = map[key];
  return v is String && v.isNotEmpty ? v : null;
}
