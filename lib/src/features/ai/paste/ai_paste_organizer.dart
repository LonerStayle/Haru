import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/category.dart';
import '../ai_call.dart';
import '../ai_gateway.dart';
import '../ai_json.dart';

/// AI 가 뽑은 할 일 초안 한 건. 패널에서 고친 뒤 [AddTodoSubmission] 으로 바뀐다.
class AiPasteDraft {
  AiPasteDraft({
    required this.title,
    this.categoryId,
    this.date,
    this.timeAnchor = 'start',
    this.evidence,
    this.children = const [],
  });

  String title;

  /// null = 시트의 현재 카테고리.
  String? categoryId;

  /// 원문에 날짜 표현이 있을 때만. 대표님이 칩을 눌러 지울 수 있다.
  AiDate? date;

  final String timeAnchor;

  /// 근거가 된 원문 구절 (원문에 실제로 있을 때만).
  final String? evidence;

  final List<AiPasteChild> children;
  bool selected = true;
}

class AiPasteChild {
  AiPasteChild(this.title);

  final String title;
  bool selected = true;
}

/// T2 — 붙여넣은 글(회의록·메일·메모)에서 할 일 초안 뽑기.
class AiPasteOrganizer {
  const AiPasteOrganizer();

  static const maxInput = 6000;

  static const instructions = '''
너는 할 일 앱의 붙여넣기 정리 도우미다. 사용자가 붙여넣은 글(회의록·메일·메모)에서 사용자가 해야 할 일을 뽑는다.
규칙:
1. 할 일이 아닌 줄(인사, 서명, 참고 정보, 이미 끝난 일, 다른 사람의 일)은 버린다.
2. 줄바꿈으로 끊긴 문장은 이어서 한 항목으로 만든다.
3. 소제목 아래에 딸린 항목은 소제목을 부모로, 딸린 줄을 children 으로 둔다. children 아래로는 더 내려가지 않는다.
4. title 은 원문 표현을 살린 한국어 한 줄, 40자 이내.
5. 날짜는 원문에 명시된 표현(오늘, 내일, 다음 주 금요일, 10월 15일, 15일 등)이 있을 때만 today 기준으로 해석해 date(YYYY-MM-DD)에 넣는다. 시각이 있으면 time(HH:mm, 24시간). 날짜를 만든 원문 구절을 dateEvidence 에 그대로 복사한다. 표현이 없으면 date·time·dateEvidence 모두 null. "까지/마감"이면 timeAnchor 를 "end", 아니면 "start".
6. "매주", "매달" 같은 반복 표현은 날짜로 만들지 말고 제목에 남긴다.
7. categoryId 는 categories 중 가장 맞는 id. 애매하면 null. categories 가 없으면 null.
8. evidence 는 그 항목의 근거가 된 원문 구절을 그대로 복사한다(60자 이내).
출력은 JSON 하나.''';

  static const schema = <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['items'],
    'properties': {
      'items': {
        'type': 'array',
        'maxItems': 30,
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'title',
            'categoryId',
            'date',
            'time',
            'timeAnchor',
            'dateEvidence',
            'evidence',
            'children',
          ],
          'properties': {
            'title': {'type': 'string'},
            'categoryId': {
              'type': ['string', 'null'],
            },
            'date': {
              'type': ['string', 'null'],
            },
            'time': {
              'type': ['string', 'null'],
            },
            'timeAnchor': {
              'type': 'string',
              'enum': ['start', 'end'],
            },
            'dateEvidence': {
              'type': ['string', 'null'],
            },
            'evidence': {
              'type': ['string', 'null'],
            },
            'children': {
              'type': 'array',
              'maxItems': 10,
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'required': ['title', 'evidence'],
                'properties': {
                  'title': {'type': 'string'},
                  'evidence': {
                    'type': ['string', 'null'],
                  },
                },
              },
            },
          },
        },
      },
    },
  };

  /// 초안 목록. 응답을 못 받으면 null, 할 일이 없으면 빈 목록.
  ///
  /// [childMode] 면 카테고리를 보내지 않는다(전부 그 부모 아래로 간다).
  Future<List<AiPasteDraft>?> organize(
    AiGateway gateway, {
    required String raw,
    required List<Category> categories,
    required String defaultCategoryId,
    required bool childMode,
    required DateTime today,
  }) {
    final text = raw.length > maxInput ? raw.substring(0, maxInput) : raw;
    return aiJson(
      gateway,
      instructions: instructions,
      input: jsonEncode({
        'today': AiJson.today(today),
        'tz': today.timeZoneName,
        'childMode': childMode,
        if (!childMode) ...{
          'defaultCategoryId': defaultCategoryId,
          'categories': [
            for (final c in categories) {'id': c.id, 'label': c.label},
          ],
        },
        'text': text,
      }),
      schema: schema,
      parse: (json) => parsePasteDrafts(
        json,
        raw: text,
        categoryIds: childMode ? const {} : {for (final c in categories) c.id},
        today: today,
      ),
    );
  }
}

/// 응답 → 초안. 원문에 없는 날짜 근거·근거 구절은 버리고, 모르는 카테고리는 null(시트 기본).
List<AiPasteDraft>? parsePasteDrafts(
  Map<String, dynamic> json, {
  required String raw,
  required Set<String> categoryIds,
  required DateTime today,
}) {
  final items = json['items'];
  if (items is! List) return null;
  final drafts = <AiPasteDraft>[];
  for (final i in AiJson.objects(items).take(30)) {
    final title = AiJson.title(i['title']);
    if (title == null) continue;
    final category = AiJson.text(i['categoryId']);
    final dateEvidence = AiJson.text(i['dateEvidence']);
    // "원문에 명시된 날짜만" 의 기계적 확인 — 근거 구절이 원문에 없으면 날짜를 버린다.
    final date = AiJson.appearsIn(dateEvidence, raw)
        ? AiJson.date(i['date'], i['time'], today: today)
        : null;
    final evidence = AiJson.text(i['evidence'], max: 60);
    drafts.add(
      AiPasteDraft(
        title: title,
        categoryId: categoryIds.contains(category) ? category : null,
        date: date,
        timeAnchor: date != null && !date.allDay && i['timeAnchor'] == 'end'
            ? 'end'
            : 'start',
        evidence: AiJson.appearsIn(evidence, raw) ? evidence : null,
        children: [
          for (final c in AiJson.objects(i['children']).take(10))
            if (AiJson.title(c['title']) case final t?) AiPasteChild(t),
        ],
      ),
    );
  }
  return drafts;
}

final aiPasteOrganizerProvider = Provider<AiPasteOrganizer>(
  (ref) => const AiPasteOrganizer(),
);
