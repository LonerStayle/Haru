/// 로그인 콜백 결과 페이지 (사양서 A.6) — 브라우저에 보여 준다.
enum SiwcCallbackPageKind { ok, denied, error, returnToApp }

/// 결과 페이지의 "하루로 돌아가기" — Android 앱 링크(매니페스트의 ai-return 필터).
const siwcReturnToAppUrl = 'com.goldenplanet.solo_todo://ai-return';

/// [code] 는 실패 원인 이름(예: `clientMismatch`) — 실기기에서 어느 단계가 막혔는지 화면만
/// 보고 알 수 있게 작게 덧붙인다. 토큰·code 같은 비밀은 넣지 않는다.
String siwcCallbackPage(SiwcCallbackPageKind kind, {String? code}) {
  final (tone, badge, title, body) = switch (kind) {
    SiwcCallbackPageKind.ok => (
      'ok',
      '연결 완료',
      'ChatGPT 플랜으로 연결됐어요',
      '이제 하루가 ChatGPT 플랜으로 답해요.',
    ),
    SiwcCallbackPageKind.denied => (
      'warn',
      '연결 안 됨',
      'ChatGPT 플랜 사용이 허용되지 않았어요',
      '하루에서 다시 허용하면 ChatGPT 플랜으로 답할 수 있어요.',
    ),
    SiwcCallbackPageKind.returnToApp => (
      'ok',
      '승인 완료',
      '하루로 돌아가 주세요',
      '하루로 돌아가면 연결을 마쳐요. 결과는 하루 화면에 나와요.',
    ),
    SiwcCallbackPageKind.error => (
      'err',
      '연결 안 됨',
      '연결하지 못했어요',
      '로그인 요청이 만료됐거나 확인되지 않았어요. 하루에서 다시 시도해 주세요.',
    ),
  };
  const hint = '이 창을 닫고 하루로 돌아가 주세요.';
  final color = switch (tone) {
    'ok' => '#1f9d55',
    'warn' => '#b7791f',
    _ => '#c53030',
  };
  return '<!doctype html><html lang="ko"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<meta name="referrer" content="no-referrer">'
      '<title>${htmlEscape('하루 · ChatGPT 연결')}</title>'
      '<style>'
      'body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",'
      'sans-serif;background:#f5f5f7;color:#1d1d1f;display:flex;min-height:100vh;'
      'align-items:center;justify-content:center;padding:16px;box-sizing:border-box}'
      '.card{background:#fff;border-radius:16px;padding:32px 28px;max-width:420px;'
      'width:100%;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center}'
      '.badge{display:inline-block;font-size:13px;font-weight:600;padding:4px 12px;'
      'border-radius:999px;color:#fff;background:$color}'
      'h1{font-size:20px;margin:16px 0 8px}p{font-size:15px;line-height:1.5;margin:8px 0}'
      '.hint{color:#6e6e73;font-size:13px;margin-top:20px}'
      '@media (prefers-color-scheme: dark){body{background:#000;color:#f5f5f7}'
      '.card{background:#1c1c1e;box-shadow:none}.hint{color:#98989d}}'
      '</style></head><body><div class="card">'
      '<span class="badge">${htmlEscape(badge)}</span>'
      '<h1>${htmlEscape(title)}</h1>'
      '<p>${htmlEscape(body)}</p>'
      '${kind == SiwcCallbackPageKind.returnToApp ? '<p><a href="$siwcReturnToAppUrl" style="display:inline-block;margin-top:12px;padding:12px 20px;border-radius:12px;background:$color;color:#fff;text-decoration:none;font-weight:600">하루로 돌아가기</a></p>' : ''}'
      '<p class="hint">${htmlEscape(hint)}</p>'
      '${code == null ? '' : '<p class="hint">원인: ${htmlEscape(code)}</p>'}'
      '</div></body></html>';
}

String htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#x27;');
