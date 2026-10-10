import 'package:flutter_test/flutter_test.dart';
import 'package:solo_todo/src/features/ai/claude/claude_api_backend.dart';

/// 폰에서 복사한 키에 섞여 오는 것들 — 실기기에서 "키를 넣어 주세요" 로 거절됐다.
void main() {
  const key = 'sk-ant-api03-AbC_d-123xyz';

  test('양끝 공백·줄바꿈', () {
    expect(extractClaudeApiKey('  $key \n'), key);
  });

  test('보이지 않는 문자(zero-width space·BOM·NBSP 계열)가 앞이나 중간에 섞임', () {
    expect(extractClaudeApiKey('​$key'), key);
    expect(extractClaudeApiKey('﻿sk-ant-api03-​AbC_d-123xyz'), key);
    expect(extractClaudeApiKey('sk-ant-api03-AbC_d-\n123xyz'), key);
  });

  test('앞말이 붙어 옴', () {
    expect(extractClaudeApiKey('ANTHROPIC_API_KEY=$key'), key);
    expect(extractClaudeApiKey('"$key"'), key);
  });

  test('키가 없으면 null', () {
    expect(extractClaudeApiKey(''), isNull);
    expect(extractClaudeApiKey('sk-proj-abc'), isNull);
  });
}
