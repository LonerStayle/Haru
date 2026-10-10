import 'dart:convert';
import 'dart:io' show HttpDate;

/// ChatGPT 호출 실패 분류 (사양서 A.14).
enum ChatGptErrorKind {
  authRequired,
  authRejected,
  usageLimited,
  serviceUnavailable,
  notEligible,
  permissionContext,
  clientBug,
  unsupportedCapability,
  modelUnavailable,
  forbidden,
  quotaExhausted,
  rateLimited,
  server,
  badRequest,
  contextTooLong,
  network,
  incomplete,
  protocol,
  refreshDeferred,
}

/// 왜 로그인이 필요한지.
enum ChatGptAuthReason { signedOut, signingOut, needsReauth, planScopeMissing }

/// ChatGPT 경로의 실패. [userMessage] 는 화면에 그대로 보여도 되는 문구.
///
/// 토큰·본문은 담지 않는다 — [code]·[param] 은 서버가 준 기계 값만.
class ChatGptException implements Exception {
  const ChatGptException(
    this.kind,
    this.userMessage, {
    this.retryable = false,
    this.status,
    this.code,
    this.param,
    this.detail,
    this.retryAfter,
    this.authReason,
  });

  final ChatGptErrorKind kind;
  final String userMessage;
  final bool retryable;
  final int? status;
  final String? code;
  final String? param;

  /// 서버 진단 문구 (detail·평문·message). 로그 금지 — 판정용.
  final String? detail;
  final Duration? retryAfter;
  final ChatGptAuthReason? authReason;

  @override
  String toString() =>
      'ChatGptException(${kind.name}, status=$status, code=$code, param=$param)';
}

const _modelMessage = '이 계정에서는 이 모델을 쓸 수 없어요.';

ChatGptException authRequired(ChatGptAuthReason reason, {String? code}) =>
    ChatGptException(
      ChatGptErrorKind.authRequired,
      switch (reason) {
        ChatGptAuthReason.planScopeMissing => 'ChatGPT 플랜 사용을 다시 허용해 주세요.',
        ChatGptAuthReason.signingOut => 'ChatGPT 연결을 해제하는 중이에요.',
        _ => 'ChatGPT 로그인이 필요해요.',
      },
      authReason: reason,
      code: code,
    );

const networkError = ChatGptException(
  ChatGptErrorKind.network,
  '네트워크 연결을 확인해 주세요.',
  retryable: true,
);

enum ErrorShape { error, detail, plain, empty }

/// 오류 본문의 세 모양 — `{"error":{…}}` / `{"detail":"…"}` / 평문.
class ApiErrorBody {
  const ApiErrorBody({
    required this.shape,
    this.type,
    this.code,
    this.param,
    this.message,
  });

  final ErrorShape shape;
  final String? type;
  final String? code;
  final String? param;
  final String? message;

  static ApiErrorBody parse(String? body) {
    if (body == null || body.trim().isEmpty) {
      return const ApiErrorBody(shape: ErrorShape.empty);
    }
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return ApiErrorBody(shape: ErrorShape.plain, message: _clip(body));
    }
    if (json is Map) {
      final err = json['error'];
      if (err is Map) {
        return ApiErrorBody(
          shape: ErrorShape.error,
          type: _str(err['type']),
          code: _str(err['code']),
          param: _str(err['param']),
          message: _clip(_str(err['message'])),
        );
      }
      final detail = json['detail'];
      if (detail is String) {
        return ApiErrorBody(shape: ErrorShape.detail, message: _clip(detail));
      }
      if (err is String) {
        return ApiErrorBody(shape: ErrorShape.error, code: _str(err));
      }
    }
    return ApiErrorBody(shape: ErrorShape.plain, message: _clip(body));
  }
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

String? _clip(String? s) =>
    s == null ? null : (s.length > 300 ? s.substring(0, 300) : s);

const _quotaCodes = {
  'credit_balance_exhausted',
  'insufficient_quota',
  'organization_spend_limit_exceeded',
  'project_spend_limit_exceeded',
  'organization_usage_limit_exceeded',
};

final _modelNotSupported = RegExp(
  r'\bmodel\b.*\bnot supported\b',
  caseSensitive: false,
);

/// 코드 우선 표 — HTTP·스트림 공통. 모르는 code 면 null.
ChatGptException? _byCode(
  String? code,
  String? param, {
  int? status,
  String? detail,
}) {
  switch (code) {
    case 'subscription_sharing_usage_limit_exceeded':
      return ChatGptException(
        ChatGptErrorKind.usageLimited,
        'ChatGPT 플랜 사용량 한도에 도달했어요.',
        status: status,
        code: code,
      );
    case 'subscription_sharing_usage_unavailable':
    case 'subscription_sharing_user_unavailable':
      return ChatGptException(
        ChatGptErrorKind.serviceUnavailable,
        'ChatGPT 연결이 잠시 불안정해요.',
        retryable: true,
        status: status,
        code: code,
      );
    case 'subscription_sharing_user_not_eligible':
      return ChatGptException(
        ChatGptErrorKind.notEligible,
        '이 ChatGPT 계정에서는 하루가 플랜을 쓸 수 없어요.',
        status: status,
        code: code,
      );
    case 'chatpass_v2_scope_not_authorized':
    case 'chatpass_v2_invalid_authorization_context':
      return ChatGptException(
        ChatGptErrorKind.permissionContext,
        'ChatGPT 연결 설정에 문제가 있어요.',
        status: status,
        code: code,
      );
    case 'subscription_sharing_route_not_supported':
      return ChatGptException(
        ChatGptErrorKind.clientBug,
        '하루 쪽 문제로 요청을 보내지 못했어요.',
        status: status,
        code: code,
      );
    case 'subscription_sharing_invalid_user':
      return ChatGptException(
        ChatGptErrorKind.authRejected,
        'ChatGPT가 요청을 확인하지 못했어요.',
        status: status,
        code: code,
      );
    case 'subscription_sharing_unsupported_capability':
      if (param == 'model' || param == 'service_tier') {
        return ChatGptException(
          ChatGptErrorKind.modelUnavailable,
          _modelMessage,
          status: status,
          code: code,
          param: param,
        );
      }
      return ChatGptException(
        ChatGptErrorKind.unsupportedCapability,
        '하루가 지원되지 않는 요청을 보냈어요.',
        status: status,
        code: code,
        param: param,
        detail: detail,
      );
    case 'model_not_found':
      return ChatGptException(
        ChatGptErrorKind.modelUnavailable,
        _modelMessage,
        status: status,
        code: code,
        param: param,
      );
  }
  return null;
}

/// HTTP 비성공 응답 분류.
ChatGptException classifyHttp(
  int status,
  ApiErrorBody err, {
  Duration? retryAfter,
}) {
  final byCode = _byCode(
    err.code,
    err.param,
    status: status,
    detail: err.message,
  );
  if (byCode != null) return byCode;

  ChatGptException make(
    ChatGptErrorKind kind,
    String message, {
    bool retryable = false,
  }) => ChatGptException(
    kind,
    message,
    retryable: retryable,
    status: status,
    code: err.code,
    param: err.param,
    detail: err.message,
    retryAfter: retryAfter,
  );

  if (status == 401) {
    return make(ChatGptErrorKind.authRejected, 'ChatGPT가 요청을 확인하지 못했어요.');
  }
  if (status == 403) {
    return make(ChatGptErrorKind.forbidden, '이 지역이나 계정에서 사용할 수 없는 요청이에요.');
  }
  if (status == 429) {
    if (err.type == 'insufficient_quota' || _quotaCodes.contains(err.code)) {
      return make(ChatGptErrorKind.quotaExhausted, 'ChatGPT 사용 한도를 모두 썼어요.');
    }
    return make(
      ChatGptErrorKind.rateLimited,
      '요청이 많아요. 잠시 후 다시 시도해 주세요.',
      retryable: true,
    );
  }
  if ((status == 400 || status == 404) &&
      (err.param == 'model' ||
          (err.code == null &&
              err.message != null &&
              _modelNotSupported.hasMatch(err.message!)))) {
    return make(ChatGptErrorKind.modelUnavailable, _modelMessage);
  }
  if (status == 503 && err.code == null) {
    return make(
      ChatGptErrorKind.serviceUnavailable,
      'ChatGPT 연결이 잠시 불안정해요.',
      retryable: true,
    );
  }
  if (status == 408 || status == 409 || status >= 500) {
    return make(
      ChatGptErrorKind.server,
      'ChatGPT 서버가 응답하지 않아요.',
      retryable: true,
    );
  }
  if (err.code == 'context_length_exceeded') {
    return make(ChatGptErrorKind.contextTooLong, '보낼 내용이 너무 길어요.');
  }
  return make(ChatGptErrorKind.badRequest, 'ChatGPT 요청이 거절됐어요 ($status).');
}

/// 스트림 오류(`response.failed` / `error` 이벤트) 분류.
ChatGptException classifyStreamError({
  String? type,
  String? code,
  String? param,
  String? message,
}) {
  final byCode = _byCode(code, param, detail: message);
  if (byCode != null) return byCode;
  if (type == 'insufficient_quota' || _quotaCodes.contains(code)) {
    return ChatGptException(
      ChatGptErrorKind.quotaExhausted,
      'ChatGPT 사용 한도를 모두 썼어요.',
      code: code,
    );
  }
  if (type == 'rate_limit_error' ||
      code == 'rate_limit_exceeded' ||
      code == 'slow_down') {
    return ChatGptException(
      ChatGptErrorKind.rateLimited,
      '요청이 많아요. 잠시 후 다시 시도해 주세요.',
      retryable: true,
      code: code,
    );
  }
  if (type == 'server_error' ||
      code == 'server_error' ||
      code == 'server_is_overloaded') {
    return ChatGptException(
      ChatGptErrorKind.server,
      'ChatGPT 서버가 응답하지 않아요.',
      retryable: true,
      code: code,
    );
  }
  if (param == 'model') {
    return ChatGptException(
      ChatGptErrorKind.modelUnavailable,
      _modelMessage,
      code: code,
      param: param,
    );
  }
  if (code == 'context_length_exceeded') {
    return ChatGptException(
      ChatGptErrorKind.contextTooLong,
      '보낼 내용이 너무 길어요.',
      code: code,
    );
  }
  return ChatGptException(
    ChatGptErrorKind.badRequest,
    'ChatGPT 요청이 거절됐어요.',
    code: code,
    param: param,
    detail: message,
  );
}

/// `retry-after-ms` 우선 → `Retry-After`(초 또는 HTTP-date). 음수·파싱 불가 → null.
Duration? parseRetryAfter(
  String? retryAfterMs,
  String? retryAfter, {
  DateTime? now,
}) {
  final ms = double.tryParse(retryAfterMs?.trim() ?? '');
  if (ms != null && ms >= 0) return Duration(microseconds: (ms * 1000).round());
  final raw = retryAfter?.trim();
  if (raw == null || raw.isEmpty) return null;
  final secs = double.tryParse(raw);
  if (secs != null) {
    return secs >= 0 ? Duration(microseconds: (secs * 1e6).round()) : null;
  }
  try {
    final at = HttpDate.parse(raw);
    final diff = at.difference(now ?? DateTime.now());
    return diff.isNegative ? null : diff;
  } catch (_) {
    return null;
  }
}
