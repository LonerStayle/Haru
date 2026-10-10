import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/todo.dart';
import '../ai_gateway.dart';
import 'ai_ask_payload.dart';

/// T5 — ⌘K 물어보기 (읽기 전용).
///
/// 할 일 목록 + 질문을 보내고 답을 텍스트 조각 스트림으로 받는다. 답 안의 `[#n]` 은
/// 보낸 번호만 인용 칩이 된다([parseCitations]). 이 서비스와 화면은 **아무것도 쓰지
/// 않는다** — 저장소·todoActions 에 손대지 않는다.
class AiAskService {
  const AiAskService();

  static const instructions = '''
너는 사용자의 할 일 목록을 읽고 질문에 답하는 도우미다. todos 에 있는 정보만 근거로 쓴다.
todos 의 키: n 번호, t 제목, c 카테고리, k task|note, s undone|doing|done, d 일정(로컬 시각), doneOn 완료한 날, p 부모의 n, desc 설명 앞부분. today 는 오늘 날짜다.
규칙:
1. 한국어로 짧게 답한다. 8줄 이내, 필요하면 "- " 목록.
2. 할 일을 언급할 때마다 바로 뒤에 [#n] 을 붙인다(n 은 todos 의 n). 없는 n 을 만들지 않는다.
3. 목록에서 답을 찾을 수 없으면 그렇다고 말한다. 추측으로 할 일을 지어내지 않는다.
4. 할 일을 바꾸라고 지시하지 않는다. 너는 읽기만 한다.''';

  /// 질문을 보낸다. 스트림은 구독할 때 시작되고, 구독을 취소하면 멈춘다.
  AiAskRequest ask(
    AiGateway gateway, {
    required String question,
    required List<Todo> all,
    required Set<String> archivedCategoryIds,
    required bool sendDescription,
    required DateTime now,
  }) {
    final payload = buildAskPayload(
      question: question,
      all: all,
      archivedCategoryIds: archivedCategoryIds,
      sendDescription: sendDescription,
      now: now,
    );
    return AiAskRequest(
      stream: gateway.stream(instructions: instructions, input: payload.input),
      nToId: payload.nToId,
    );
  }
}

/// 보낸 질문 하나 — 답 조각 스트림 + 인용 역매핑표.
class AiAskRequest {
  const AiAskRequest({required this.stream, required this.nToId});

  final Stream<String> stream;
  final Map<int, String> nToId;
}

final aiAskServiceProvider = Provider<AiAskService>(
  (ref) => const AiAskService(),
);

/// 답에서 인용된 할 일 하나. [index] 는 화면에 보이는 번호(첫 등장 순, 1부터).
class AiAskCitation {
  const AiAskCitation({
    required this.index,
    required this.n,
    required this.todoId,
  });

  final int index;
  final int n;
  final String todoId;

  @override
  bool operator ==(Object other) =>
      other is AiAskCitation &&
      other.index == index &&
      other.n == n &&
      other.todoId == todoId;

  @override
  int get hashCode => Object.hash(index, n, todoId);

  @override
  String toString() => 'AiAskCitation($index, n: $n, $todoId)';
}

/// 화면에 올릴 답 — 다듬은 본문 + 인용 칩.
class AiAskAnswer {
  const AiAskAnswer({required this.text, required this.citations});

  static const empty = AiAskAnswer(text: '', citations: []);

  final String text;
  final List<AiAskCitation> citations;
}

/// 인용 칩 상한.
const int aiAskMaxCitations = 10;

final _marker = RegExp(r'( ?)\[#(\d+)\]');

/// 스트림 끝에 아직 덜 온 표식(`[`, `[#`, `[#12`).
final _partialTail = RegExp(r' ?\[(#\d*)?$');

/// 답 원문 → 본문 + 인용.
///
/// - `[#n]` 중 [nToId] 에 있는 번호만 칩이 된다(첫 등장 순, 최대 [aiAskMaxCitations]).
///   본문의 표식은 칩 번호 `[1]` 로 바꿔 칩과 맞춘다.
/// - 보내지 않은 번호(지어낸 인용)·상한을 넘는 인용은 본문에서 지운다.
/// - 스트림 도중 끝에 걸린 덜 온 표식은 완성될 때까지 숨긴다.
AiAskAnswer parseCitations(String raw, Map<int, String> nToId) {
  final source = raw.replaceFirst(_partialTail, '');
  final indexOfN = <int, int>{};
  final citations = <AiAskCitation>[];
  final text = source.replaceAllMapped(_marker, (m) {
    final n = int.tryParse(m[2]!);
    final id = n == null ? null : nToId[n];
    if (id == null) return '';
    var index = indexOfN[n];
    if (index == null) {
      if (citations.length >= aiAskMaxCitations) return '';
      index = citations.length + 1;
      indexOfN[n!] = index;
      citations.add(AiAskCitation(index: index, n: n, todoId: id));
    }
    return '${m[1]}[$index]';
  });
  return AiAskAnswer(text: text.trim(), citations: citations);
}
