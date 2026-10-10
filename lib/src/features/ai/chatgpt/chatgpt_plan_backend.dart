import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/platform.dart';
import '../ai_backend.dart';
import '../ai_gateway.dart';
import '../ai_route.dart';
import 'chatgpt_client.dart';
import 'chatgpt_gateway.dart';
import 'chatgpt_models.dart';
import 'siwc_account.dart';
import 'siwc_config.dart';
import 'siwc_credentials.dart';
import 'siwc_login.dart';
import 'siwc_store.dart';
import 'siwc_token_endpoint.dart';

export 'siwc_login.dart' show OpenUrl;

/// ChatGPT 플랜(Sign in with ChatGPT) 백엔드.
///
/// 로그인은 loopback(127.0.0.1:1455 → 실패 시 임의 포트) 콜백, 호출은 `/v1/responses`.
/// 로그인 정보는 이 기기의 앱 지원 폴더 JSON 파일에만 둔다 (동기화하지 않는다).
class ChatGptPlanBackend implements AiBackend {
  ChatGptPlanBackend({
    http.Client? httpClient,
    SiwcStore? store,
    OpenUrl? openUrl,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    Random? random,
    this.preferredPort = SiwcConfig.preferredPort,
    this.model,
  }) : _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _openUrl = openUrl ?? openInBrowser,
       _clock = clock ?? DateTime.now,
       _random = random {
    int nowMs() => _clock().millisecondsSinceEpoch;
    _endpoint = SiwcTokenEndpoint(client: _http, nowMs: nowMs);
    _credentials = SiwcCredentials(
      store: store ?? SiwcFileStore(),
      endpoint: _endpoint,
      nowMs: nowMs,
      sleep: sleep,
      onChanged: _emit,
    );
    _client = ChatGptClient(
      client: _http,
      credentials: _credentials,
      sleep: sleep,
      random: random,
      clock: _clock,
      onUsageLimited: _onUsageLimited,
      onSuccess: _onCallSucceeded,
    );
    _gateway = ChatGptGateway(client: _client, model: _modelChoice);
  }

  final http.Client _http;
  final bool _ownsHttp;
  final OpenUrl _openUrl;
  final DateTime Function() _clock;
  final Random? _random;
  final int preferredPort;

  /// 고정 모델 (null 이면 카탈로그에서 고른다).
  final String? model;

  late final SiwcTokenEndpoint _endpoint;
  late final SiwcCredentials _credentials;
  late final ChatGptClient _client;
  late final ChatGptGateway _gateway;

  final _changes = StreamController<AiAccountStatus>.broadcast();
  String? _lastSignature;
  DateTime? _pausedUntil;
  Timer? _pauseTimer;
  SiwcLoginFlow? _activeLogin;
  bool _loaded = false;

  List<CatalogModel>? _catalog;
  DateTime? _catalogAt;
  DateTime? _catalogFailedAt;

  /// 마지막 로그아웃에서 원격 해제(revoke)를 확인했는지. false 면
  /// "ChatGPT 설정에서 앱 연결을 끊을 수 있어요" 안내를 띄운다.
  bool? lastSignOutRevokeConfirmed;

  @override
  AiRoute get route => AiRoute.chatgptPlan;

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

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    await _credentials.load();
    _loaded = true;
    // 로그아웃 중에 앱이 죽었으면 이어서 끝낸다.
    if (_credentials.account?.state == SiwcAccountState.signingOut) {
      unawaited(signOut());
    }
  }

  @override
  Future<void> signIn(AiSignInPrompter prompter) async {
    await _ensureLoaded();
    _activeLogin?.cancel();
    final flow = SiwcLoginFlow(
      credentials: _credentials,
      endpoint: _endpoint,
      openUrl: _openUrl,
      nowMs: () => _clock().millisecondsSinceEpoch,
      random: _random,
      preferredPort: preferredPort,
    );
    _activeLogin = flow;
    final SiwcAccountRecord record;
    try {
      record = await flow.run();
    } on SiwcLoginError catch (e) {
      // 원인 코드를 붙인다 — 실기기에서 어느 단계가 실패했는지 화면만 보고 알 수 있게.
      throw AiSignInException('${e.failure.userMessage} (${e.failure.name})');
    } finally {
      if (identical(_activeLogin, flow)) _activeLogin = null;
    }
    _catalog = null;
    _catalogFailedAt = null;
    _clearPause();
    _emit();
    if (!record.planUsage) {
      throw const AiSignInException(
        'ChatGPT 플랜 사용이 허용되지 않았어요. 다시 연결해서 허용해 주세요.',
      );
    }
  }

  /// 진행 중인 로그인을 취소한다 (포트 해제).
  void cancelSignIn() => _activeLogin?.cancel();

  @override
  Future<void> signOut() async {
    await _credentials.load();
    _activeLogin?.cancel();
    lastSignOutRevokeConfirmed = await _credentials.signOut();
    _catalog = null;
    _catalogFailedAt = null;
    _clearPause();
    _emit();
  }

  /// 이 계정이 쓸 수 있는 모델 (설정 화면용, `list` 만). 실패는 ChatGptException.
  Future<List<CatalogModel>> listModels({bool refresh = false}) async {
    final all = await _loadCatalog(refresh: refresh);
    return (all ?? const <CatalogModel>[]).where((m) => m.listed).toList();
  }

  Future<List<CatalogModel>?> _loadCatalog({bool refresh = false}) async {
    final at = _catalogAt;
    if (!refresh &&
        _catalog != null &&
        at != null &&
        _clock().difference(at) < SiwcConfig.modelCacheTtl) {
      return _catalog;
    }
    final List<CatalogModel>? parsed;
    try {
      parsed = parseModelCatalog(await _client.fetchModels());
    } catch (_) {
      _catalogFailedAt = _clock();
      rethrow;
    }
    _catalog = parsed;
    _catalogAt = _clock();
    _catalogFailedAt = null;
    return parsed;
  }

  Future<ChatGptModelChoice> _modelChoice() async {
    final fixed = model;
    List<CatalogModel>? catalog;
    final failedAt = _catalogFailedAt;
    // 카탈로그를 방금 못 받았으면 호출마다 다시 묻지 않는다 (10분).
    final recentlyFailed =
        _catalog == null &&
        failedAt != null &&
        _clock().difference(failedAt) < const Duration(minutes: 10);
    if (!recentlyFailed) {
      try {
        catalog = await _loadCatalog();
      } catch (_) {
        catalog = null;
      }
    }
    if (fixed != null) {
      final match = catalog?.where((m) => m.slug == fixed).firstOrNull;
      return (slug: fixed, effort: reasoningEffortFor(match));
    }
    final chosen = chooseDefaultModel(catalog);
    return (
      slug: chosen?.slug ?? SiwcConfig.defaultModel,
      effort: reasoningEffortFor(chosen),
    );
  }

  void _onUsageLimited() {
    final until = _clock().add(SiwcConfig.usagePause);
    _pausedUntil = until;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(SiwcConfig.usagePause, () {
      _pausedUntil = null;
      _emit();
    });
    _emit();
  }

  void _onCallSucceeded() {
    if (_pausedUntil == null) return;
    _clearPause();
    _emit();
  }

  void _clearPause() {
    _pausedUntil = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
  }

  AiAccountStatus _status() {
    final rec = _credentials.account;
    if (rec == null ||
        rec.state != SiwcAccountState.signedIn ||
        !rec.planUsage) {
      return const AiSignedOut();
    }
    final label = rec.email ?? 'ChatGPT 계정';
    final until = _pausedUntil;
    if (until != null && _clock().isBefore(until)) {
      return AiPaused(label: label, until: until);
    }
    return AiSignedIn(label: label, plan: _planLabel(rec.plan));
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
    AiSignedIn(:final label, :final plan) => 'in|$label|$plan',
    AiPaused(:final label, :final until) => 'paused|$label|$until',
  };

  static String? _planLabel(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return raw[0].toUpperCase() + raw.substring(1);
  }

  void dispose() {
    _activeLogin?.cancel();
    _pauseTimer?.cancel();
    unawaited(_changes.close());
    if (_ownsHttp) _http.close();
  }
}

/// 기본 브라우저 열기 — macOS 는 `open`(하루 Microsoft·Google 연동과 같은 방식),
/// Android 는 Custom Tabs(`inAppBrowserView`), 안 되면 외부 브라우저.
Future<bool> openInBrowser(String url) async {
  if (AppPlatform.isDesktop) {
    final result = await Process.run('open', [url]);
    return result.exitCode == 0;
  }
  final uri = Uri.parse(url);
  try {
    if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
  } catch (_) {}
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// 앱 전역 ChatGPT 플랜 백엔드 — `aiBackendProvider` 의 chatgptPlan 자리에 끼운다.
final chatGptPlanBackendProvider = Provider<ChatGptPlanBackend>((ref) {
  final backend = ChatGptPlanBackend();
  ref.onDispose(backend.dispose);
  return backend;
});
