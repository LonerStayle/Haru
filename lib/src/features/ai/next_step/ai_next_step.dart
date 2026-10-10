import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/todo.dart';
import '../ai_call.dart';
import '../ai_gateway.dart';
import '../ai_json.dart';

/// T4 — 장기 목표·아이디어에서 오늘 시작할 첫 행동 하나.
class AiNextStep {
  const AiNextStep({required this.title, required this.minutes, this.why});

  final String title;

  /// 예상 시간(분). 5~30 으로 맞춘다.
  final int minutes;

  /// 이 행동이 주제를 앞당기는 이유. 없을 수 있다.
  final String? why;

  @override
  bool operator ==(Object other) =>
      other is AiNextStep &&
      other.title == title &&
      other.minutes == minutes &&
      other.why == why;

  @override
  int get hashCode => Object.hash(title, minutes, why);

  @override
  String toString() => 'AiNextStep($title, $minutes분, $why)';
}

/// "다음 한 걸음" 제안 — 결과는 제안만 한다. 저장은 대표님이 행을 누를 때
/// 기존 하위 추가 경로(`AddTodoController.add`)로만.
class AiNextStepService {
  const AiNextStepService();

  /// 대상 카테고리 — 장기 목표·아이디어 (id 고정).
  static const categoryIds = {'longterm', 'idea'};

  /// 제안 개수 상한.
  static const maxSteps = 3;

  /// 카드를 보일 항목인지 — 장기 목표·아이디어의 미완료, 반복 아님.
  ///
  /// 반복 컬럼은 원격으로 동기화되지 않아 AI 경로에서 반복 항목은 다루지 않는다.
  static bool applies(Todo todo) =>
      !todo.isDone &&
      categoryIds.contains(todo.category.id) &&
      !todo.isInRecurringSeries;

  static const instructions = '''
너는 장기 목표와 아이디어를 실행으로 옮기도록 돕는다. 주제 하나를 받아 오늘 30분 안에 시작할 수 있는 첫 행동 3개를 제안한다.
규칙:
1. 각 행동은 결과물이 분명한 한국어 한 줄, 30자 이내, 동사로 끝낸다. (예: "경쟁 앱 3개 스크린샷 모으기")
2. 세 행동은 성격이 달라야 한다(조사 / 결정 / 만들기 등).
3. 설명에 이미 끝났다고 적힌 일은 제안하지 않는다.
4. minutes 는 5~30 사이 예상 시간. why 는 이 행동이 주제를 앞당기는 이유, 20자 이내.
출력은 JSON 하나.''';

  static const schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['steps'],
    'properties': {
      'steps': {
        'type': 'array',
        'maxItems': maxSteps,
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['title', 'minutes', 'why'],
          'properties': {
            'title': {'type': 'string'},
            'minutes': {'type': 'integer'},
            'why': {'type': 'string'},
          },
        },
      },
    },
  };

  /// AI 로 보내는 입력 — 항목 하나를 골라 부르는 기능이라 설명(앞 300자)을 항상 보낸다.
  ///
  /// [path] 는 위쪽 조상 제목(바깥 → 안쪽).
  static String buildInput(Todo todo, {List<String> path = const []}) {
    final description = todo.description?.trim();
    return jsonEncode({
      'title': todo.title,
      'category': todo.category.label,
      'path': path,
      'description': description == null || description.isEmpty
          ? null
          : description.length > 300
          ? description.substring(0, 300)
          : description,
    });
  }

  /// 제안 목록. 응답이 없거나 모양이 틀리면 null, 쓸 만한 제안이 없으면 빈 목록.
  Future<List<AiNextStep>?> suggest(
    AiGateway gateway,
    Todo todo, {
    List<String> path = const [],
  }) => aiJson(
    gateway,
    instructions: instructions,
    input: buildInput(todo, path: path),
    schema: schema,
    parse: (json) => parseNextSteps(json, parentTitle: todo.title),
  );
}

/// 응답 → 제안 목록 (순수 함수).
///
/// - `steps` 가 배열이 아니면 null (최상위가 틀림).
/// - 제목·예상 시간이 틀린 원소는 그 원소만 버린다. 이유는 없어도 된다.
/// - 부모와 같은 제목, 중복 제목은 버린다(공백·대소문자 무시).
/// - 예상 시간은 5~30 으로 맞추고, 앞에서부터 최대 3개.
List<AiNextStep>? parseNextSteps(
  Map<String, dynamic> json, {
  required String parentTitle,
}) {
  final raw = json['steps'];
  if (raw is! List) return null;
  String key(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  final seen = <String>{key(parentTitle)};
  final steps = <AiNextStep>[];
  for (final e in AiJson.objects(raw)) {
    if (steps.length >= AiNextStepService.maxSteps) break;
    final title = AiJson.title(e['title']);
    final minutes = AiJson.integer(e['minutes']);
    if (title == null || minutes == null) continue;
    if (!seen.add(key(title))) continue;
    steps.add(
      AiNextStep(
        title: title,
        minutes: minutes.clamp(5, 30),
        why: AiJson.text(e['why'], max: 40),
      ),
    );
  }
  return steps;
}

final aiNextStepServiceProvider = Provider<AiNextStepService>(
  (ref) => const AiNextStepService(),
);
