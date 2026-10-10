import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../ai_backend.dart';
import '../ai_gateway.dart';
import '../ai_route.dart';
import 'claude_config.dart';
import 'claude_gateway.dart';
import 'claude_key_store.dart';
import 'claude_messages_client.dart';

/// Claude — Anthropic API 키 백엔드 (구독 로그인 아님).
///
/// 키는 이 기기의 앱 지원 폴더 JSON 파일에만 둔다 (동기화·백업하지 않는다).
/// 키·요청/응답 본문은 로그·예외·toString 어디에도 남기지 않는다.
class ClaudeApiBackend implements AiBackend {
  ClaudeApiBackend({
    http.Client? httpClient,
    ClaudeKeyStore? store,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _store = store ?? ClaudeKeyFileStore(),
       _clock = clock ?? DateTime.now {
    _client = ClaudeMessagesClient(
      client: _http,
      apiKey: _currentKey,
      sleep: sleep,
      onRateLimited: _onRateLimited,
      onUnauthorized: _onUnauthorized,
      onSuccess: _onSuccess,
    );
    _gateway = ClaudeGateway(client: _client);
  }

  final http.Client _http;
  final bool _ownsHttp;
  final ClaudeKeyStore _store;
  final DateTime Function() _clock;

  late final ClaudeMessagesClient _client;
  late final ClaudeGateway _gateway;

  final _changes = StreamController<AiAccountStatus>.broadcast();
  String? _lastSignature;
  String? _key;
  bool _loaded = false;
  Future<void>? _loading;

  /// 마지막 호출이 401 — 키는 남기고 "거부됨" 만 표시한다.
  bool _rejected = false;
  DateTime? _pausedUntil;
  Timer? _pauseTimer;

  @override
  AiRoute get route => AiRoute.claudeApi;

  @override
  AiGateway get gateway => _gateway;

  @override
  Stream<AiAccountStatus> watchStatus() async* {
    await _ensureLoaded();
    final first = _status();
    _lastSignature = _signature(first);
    yield first;
    yield* _changes.stream;
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= () async {
      _key = await _store.read();
      _loaded = true;
    }();
  }

  Future<String?> _currentKey() async {
    await _ensureLoaded();
    return _key;
  }

  @override
  Future<void> signIn(AiSignInPrompter prompter) async {
    await _ensureLoaded();
    final raw = await prompter.askSecret(
      title: 'Anthropic API 키',
      hint: '${ClaudeConfig.keyPrefix}…',
    );
    if (raw == null) return;
    final key = extractClaudeApiKey(raw);
    if (key == null) {
      throw const AiSignInException('Anthropic API 키(sk-ant-…)를 넣어 주세요');
    }
    final int status;
    try {
      status = await _client.verifyKey(key);
    } catch (_) {
      throw const AiSignInException('확인하지 못했어요 · 잠시 후 다시');
    }
    if (status == 401) throw const AiSignInException('키가 맞지 않아요');
    if (status != 200) {
      throw const AiSignInException('확인하지 못했어요 · 잠시 후 다시');
    }
    try {
      await _store.write(key);
    } catch (_) {
      throw const AiSignInException('키를 저장하지 못했어요 · 잠시 후 다시');
    }
    _key = key;
    _rejected = false;
    _clearPause();
    _emit();
  }

  @override
  Future<void> signOut() async {
    await _ensureLoaded();
    // 파일을 지운 뒤에만 비운다 — 지우기가 실패했는데 "키 없음" 으로 보이면, 다음
    // 실행에 키가 되살아난다. 실패는 그대로 올려 설정 화면이 안내하게 한다.
    await _store.delete();
    _key = null;
    _rejected = false;
    _clearPause();
    _emit();
  }

  void _onRateLimited(Duration? retryAfter) {
    final wait = retryAfter ?? ClaudeConfig.defaultPause;
    _pausedUntil = _clock().add(wait);
    _pauseTimer?.cancel();
    _pauseTimer = Timer(wait, () {
      _pausedUntil = null;
      _pauseTimer = null;
      _emit();
    });
    _emit();
  }

  void _onUnauthorized() {
    if (_rejected) return;
    _rejected = true;
    _emit();
  }

  void _onSuccess() {
    if (!_rejected && _pausedUntil == null) return;
    _rejected = false;
    _clearPause();
    _emit();
  }

  void _clearPause() {
    _pausedUntil = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
  }

  AiAccountStatus _status() {
    final key = _key;
    if (key == null) return const AiSignedOut();
    final last4 = key.length <= 4 ? key : key.substring(key.length - 4);
    final label = 'API 키 ····$last4${_rejected ? ' · 거부됨' : ''}';
    final until = _pausedUntil;
    if (until != null && _clock().isBefore(until)) {
      return AiPaused(label: label, until: until);
    }
    return AiSignedIn(label: label, rejected: _rejected);
  }

  void _emit() {
    if (!_loaded || _changes.isClosed) return;
    final status = _status();
    final sig = _signature(status);
    if (sig == _lastSignature) return;
    _lastSignature = sig;
    _changes.add(status);
  }

  static String _signature(AiAccountStatus s) => switch (s) {
    AiSignedOut() => 'out',
    AiSignedIn(:final label, :final plan, :final rejected) =>
      'in|$label|$plan|$rejected',
    AiPaused(:final label, :final until) => 'paused|$label|$until',
  };

  void dispose() {
    _pauseTimer?.cancel();
    unawaited(_changes.close());
    if (_ownsHttp) _http.close();
  }
}

/// 앱 전역 Claude API 백엔드 — `aiBackendProvider` 의 claudeApi 자리에 끼운다.
final claudeApiBackendProvider = Provider<ClaudeApiBackend>((ref) {
  final backend = ClaudeApiBackend();
  ref.onDispose(backend.dispose);
  return backend;
});

/// 붙여넣은 글에서 API 키만 꺼낸다. 폰에서 복사하면 줄바꿈·보이지 않는 문자(zero-width
/// space 등)가 섞이거나 `ANTHROPIC_API_KEY=` 같은 앞말이 붙어 와, 양끝 trim 만으로는
/// `sk-ant-` 로 시작하지 않아 "키를 넣어 주세요" 로 거절됐다.
String? extractClaudeApiKey(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[\s​-‏  ⁠﻿]'), '');
  return RegExp(
    '${RegExp.escape(ClaudeConfig.keyPrefix)}[A-Za-z0-9_-]+',
  ).firstMatch(cleaned)?.group(0);
}
