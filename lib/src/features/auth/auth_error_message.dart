import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase auth 호출 실패를 사용자 친화 한국어 메시지로 변환.
///
/// 분기:
///   - rate limit (HTTP 429 / "over_email_send_rate_limit" / "rate" / "limit") →
///     "1분에 한 번만…" 안내
///   - invalid email → "이메일 주소 형식을 확인…"
///   - OTP 단계의 만료/불일치 → "코드가 일치하지 않거나 만료…"
///   - 네트워크 끊김 → "인터넷 연결을 확인…"
///   - 그 외 → 한국어 일반 안내 (영문 원문은 로그로만 — 화면에 그대로 띄우지 않는다)
///
/// 문구는 해요체로 통일한다.
String friendlyAuthErrorMessage(Object err, {required bool forVerify}) {
  if (_looksOffline(err)) {
    return '인터넷 연결을 확인하고 다시 시도해 주세요.';
  }
  if (err is AuthException) {
    final code = err.statusCode ?? '';
    final msg = err.message.toLowerCase();
    final isRateLimit =
        code == '429' ||
        msg.contains('over_email_send_rate_limit') ||
        msg.contains('too many') ||
        (msg.contains('rate') && msg.contains('limit'));
    if (isRateLimit) {
      return '잠시 후 다시 시도해 주세요. (코드는 1분에 한 번만 받을 수 있어요)';
    }
    if (!forVerify && msg.contains('invalid') && msg.contains('email')) {
      return '이메일 주소 형식을 확인해 주세요.';
    }
    if (forVerify &&
        (msg.contains('invalid') ||
            msg.contains('expired') ||
            msg.contains('token'))) {
      return '코드가 일치하지 않거나 만료됐어요. 새 코드를 받아 주세요.';
    }
    debugPrint('[auth] 알 수 없는 인증 오류: ${err.message}');
  }
  return forVerify
      ? '코드 확인에 실패했어요. 잠시 후 다시 시도해 주세요.'
      : '코드 발송에 실패했어요. 잠시 후 다시 시도해 주세요.';
}

/// 네트워크가 끊겨 요청 자체가 못 나간 경우.
bool _looksOffline(Object err) {
  if (err is AuthRetryableFetchException) return true;
  final text = err.toString().toLowerCase();
  return text.contains('socketexception') ||
      text.contains('failed host lookup') ||
      text.contains('network is unreachable') ||
      text.contains('connection refused');
}
