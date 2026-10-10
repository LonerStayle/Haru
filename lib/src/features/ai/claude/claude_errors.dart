/// Messages API 실패 종류 — 재시도·한도·거부 판단의 근거.
enum ClaudeErrorKind {
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  tooLarge,
  rateLimited,
  apiError,
  overloaded,
  server,
  network,
  protocol,
  refusal,
  incomplete,
  noKey,
  other;

  /// 재시도 대상 — 429·500·529 와 연결 오류만.
  bool get retryable => switch (this) {
    rateLimited || apiError || overloaded || network => true,
    _ => false,
  };
}

/// Messages API 실패. 화면에 보여도 되는 문구만 담는다 —
/// 키·요청/응답 본문·서버 오류 message 는 절대 넣지 않는다 (사용자 데이터가 섞일 수 있다).
class ClaudeApiException implements Exception {
  const ClaudeApiException(
    this.kind, {
    this.status,
    this.type,
    this.retryAfter,
  });

  final ClaudeErrorKind kind;
  final int? status;

  /// 오류 본문의 `error.type` (기계 값일 때만).
  final String? type;

  /// `retry-after` 헤더 값.
  final Duration? retryAfter;

  String get message => switch (kind) {
    ClaudeErrorKind.unauthorized => 'API 키가 거부됐어요 · 설정에서 확인',
    ClaudeErrorKind.forbidden => '이 키로는 쓸 수 없어요 · 설정에서 확인',
    ClaudeErrorKind.rateLimited => '한도에 걸렸어요 · 잠시 후 다시',
    ClaudeErrorKind.overloaded ||
    ClaudeErrorKind.apiError ||
    ClaudeErrorKind.server => 'Claude 가 지금 바빠요 · 잠시 후 다시',
    ClaudeErrorKind.network => '연결이 끊겼어요 · 잠시 후 다시',
    ClaudeErrorKind.refusal => '이 요청에는 답하지 않았어요',
    ClaudeErrorKind.incomplete => '답이 중간에 끊겼어요.',
    ClaudeErrorKind.tooLarge => '보낼 내용이 너무 길어요',
    ClaudeErrorKind.noKey => 'API 키가 필요해요 · 설정에서 입력',
    _ => 'AI 응답을 받지 못했어요',
  };

  @override
  String toString() =>
      'ClaudeApiException(${kind.name}, status=$status, type=${safeErrorType(type)})';
}

const networkFailure = ClaudeApiException(ClaudeErrorKind.network);

/// HTTP 상태 → 종류.
ClaudeErrorKind kindForStatus(int status) => switch (status) {
  400 => ClaudeErrorKind.badRequest,
  401 => ClaudeErrorKind.unauthorized,
  403 => ClaudeErrorKind.forbidden,
  404 => ClaudeErrorKind.notFound,
  413 => ClaudeErrorKind.tooLarge,
  429 => ClaudeErrorKind.rateLimited,
  500 => ClaudeErrorKind.apiError,
  529 => ClaudeErrorKind.overloaded,
  >= 500 => ClaudeErrorKind.server,
  _ => ClaudeErrorKind.other,
};

/// 스트림 `error` 이벤트·오류 본문의 `error.type` → 종류.
ClaudeErrorKind kindForType(String? type) => switch (type) {
  'invalid_request_error' => ClaudeErrorKind.badRequest,
  'authentication_error' => ClaudeErrorKind.unauthorized,
  'permission_error' => ClaudeErrorKind.forbidden,
  'not_found_error' => ClaudeErrorKind.notFound,
  'request_too_large' => ClaudeErrorKind.tooLarge,
  'rate_limit_error' => ClaudeErrorKind.rateLimited,
  'api_error' => ClaudeErrorKind.apiError,
  'overloaded_error' => ClaudeErrorKind.overloaded,
  _ => ClaudeErrorKind.other,
};

/// 오류 본문 `{type:'error', error:{type, message}}` 에서 `error.type` 만 꺼낸다.
/// message 는 읽지 않는다.
String? errorTypeOf(Object? json) {
  if (json is! Map) return null;
  final error = json['error'];
  if (error is! Map) return null;
  final type = error['type'];
  return type is String ? type : null;
}

/// `retry-after` (초, 소수 허용). 없거나 날짜 형식이면 null.
Duration? parseRetryAfterSeconds(String? raw) {
  if (raw == null) return null;
  final seconds = double.tryParse(raw.trim());
  if (seconds == null || seconds < 0 || !seconds.isFinite) return null;
  return Duration(milliseconds: (seconds * 1000).ceil());
}

final _safeType = RegExp(r'^[a-z_]{1,64}$');

/// 로그에는 기계 값 모양일 때만.
String? safeErrorType(String? v) =>
    v == null ? null : (_safeType.hasMatch(v) ? v : 'other');
