import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/claude/claude_schema.dart';
import 'package:solo_todo/src/features/ai/paste/ai_paste_organizer.dart';

void main() {
  test('타입 배열 → anyOf, 설명은 바깥에 남는다', () {
    final out = toClaudeSchema({
      'type': 'object',
      'properties': {
        'date': {
          'type': ['string', 'null'],
          'description': 'YYYY-MM-DD',
        },
        'mode': {
          'type': ['string', 'null'],
          'enum': ['a', 'b', null],
        },
        'only': {
          'type': ['integer'],
        },
      },
      'required': ['date', 'mode', 'only'],
    });
    final props = out['properties'] as Map;
    expect(props['date'], {
      'description': 'YYYY-MM-DD',
      'anyOf': [
        {'type': 'string'},
        {'type': 'null'},
      ],
    });
    expect(props['mode'], {
      'anyOf': [
        {
          'type': 'string',
          'enum': ['a', 'b'],
        },
        {'type': 'null'},
      ],
    });
    expect(props['only'], {'type': 'integer'});
    expect(out['required'], ['date', 'mode', 'only']);
  });

  test('미지원 제약 제거 · enum 유지 · 같은 이름의 속성은 지우지 않는다', () {
    final out = toClaudeSchema({
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 30,
          'items': {
            'type': 'string',
            'minLength': 1,
            'maxLength': 60,
            'pattern': r'^\d+$',
          },
        },
        'n': {'type': 'number', 'minimum': 0, 'maximum': 9, 'multipleOf': 1},
        'kind': {
          'type': 'string',
          'enum': ['x', 'y'],
        },
        // 속성 이름이 키워드와 같아도 속성은 남는다.
        'pattern': {'type': 'string'},
        'minimum': {'type': 'integer'},
      },
      'required': ['items', 'n', 'kind', 'pattern', 'minimum'],
    });
    final props = out['properties'] as Map;
    expect(props['items'], {
      'type': 'array',
      'items': {'type': 'string'},
    });
    expect(props['n'], {'type': 'number'});
    expect(props['kind'], {
      'type': 'string',
      'enum': ['x', 'y'],
    });
    expect(props['pattern'], {'type': 'string'});
    expect(props['minimum'], {'type': 'integer'});
  });

  test('모든 object 에 additionalProperties:false (중첩·nullable object 포함)', () {
    final out = toClaudeSchema({
      'type': 'object',
      'properties': {
        'child': {
          'type': 'object',
          'additionalProperties': true,
          'properties': {
            'x': {'type': 'string'},
          },
        },
        'maybe': {
          'type': ['object', 'null'],
          'properties': {
            'y': {'type': 'string'},
          },
        },
        'list': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'z': {'type': 'boolean'},
            },
          },
        },
      },
    });
    expect(out['additionalProperties'], false);
    final props = out['properties'] as Map;
    expect((props['child'] as Map)['additionalProperties'], false);
    final maybe = (props['maybe'] as Map)['anyOf'] as List;
    expect((maybe.first as Map)['additionalProperties'], false);
    expect((maybe.first as Map)['type'], 'object');
    expect(maybe.last, {'type': 'null'});
    expect(
      ((props['list'] as Map)['items'] as Map)['additionalProperties'],
      false,
    );
  });

  test('원본은 바뀌지 않는다 (깊은 복사)', () {
    final original = jsonDecode(jsonEncode(AiPasteOrganizer.schema));
    final before = jsonEncode(original);
    final out = toClaudeSchema(original as Map<String, dynamic>);
    expect(jsonEncode(original), before);
    // 변환본을 고쳐도 원본에 번지지 않는다.
    ((out['properties'] as Map)['items'] as Map)['type'] = 'changed';
    expect(jsonEncode(original), before);
    // 상수 스키마도 그대로 받는다.
    expect(() => toClaudeSchema(AiPasteOrganizer.schema), returnsNormally);
  });

  test('실제 기능 스키마 — 타입 배열·maxItems 가 남지 않는다', () {
    final text = jsonEncode(toClaudeSchema(AiPasteOrganizer.schema));
    expect(text, isNot(contains('"type":["')));
    expect(text, isNot(contains('maxItems')));
    expect(text, contains('"anyOf"'));
    expect(text, contains('"enum":["start","end"]'));
  });
}
