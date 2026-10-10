import 'ai_gateway.dart';
import 'ai_route.dart';

/// 플랜 계정 상태 — 설정 화면 표시와 기능 버튼 노출([AiReadiness])의 근거.
sealed class AiAccountStatus {
  const AiAccountStatus();
}

class AiSignedOut extends AiAccountStatus {
  const AiSignedOut();
}

class AiSignedIn extends AiAccountStatus {
  const AiSignedIn({required this.label, this.plan, this.rejected = false});

  /// 계정 표시 (이메일 등).
  final String label;

  /// 플랜 이름 (Plus / Pro / Max …). 모르면 null.
  final String? plan;

  /// 저장된 자격(API 키)이 마지막 호출에서 거부됨 (401). 키는 남아 있다.
  final bool rejected;
}

/// 한도에 걸려 [until] 까지 쉬는 중.
class AiPaused extends AiAccountStatus {
  const AiPaused({required this.label, required this.until});

  final String label;
  final DateTime until;
}

/// AI 경로 하나 — 로그인(키 입력)·로그아웃·호출 창구.
///
/// 구현: ChatGPT 플랜(SIWC) / Claude API 키. 로그인 정보는 기기별이다(동기화하지 않는다).
abstract interface class AiBackend {
  AiRoute get route;

  /// 현재 상태를 먼저 한 번 내보내고, 바뀔 때마다 다시 내보낸다.
  Stream<AiAccountStatus> watchStatus();

  /// 로그인. 실패는 [AiSignInException] (화면이 문구를 그대로 보여 준다).
  Future<void> signIn(AiSignInPrompter prompter);

  Future<void> signOut();

  AiGateway get gateway;
}

/// 로그인 중 사용자에게 받아야 하는 것.
abstract interface class AiSignInPrompter {
  /// 브라우저가 보여 준 코드를 붙여넣는다. 취소하면 null.
  Future<String?> askCode({required String message});

  /// API 키 같은 비밀값 — 가려서 입력받는다. 취소하면 null.
  Future<String?> askSecret({required String title, required String hint});
}

class AiSignInException implements Exception {
  const AiSignInException(this.message);

  final String message;

  @override
  String toString() => 'AiSignInException($message)';
}

/// 아직 백엔드가 없는 경로 — 항상 로그아웃 상태.
class NotConnectedAiBackend implements AiBackend {
  const NotConnectedAiBackend(this.route);

  @override
  final AiRoute route;

  @override
  Stream<AiAccountStatus> watchStatus() => Stream.value(const AiSignedOut());

  @override
  Future<void> signIn(AiSignInPrompter prompter) async =>
      throw const AiSignInException('이 기기에서는 아직 연결할 수 없어요');

  @override
  Future<void> signOut() async {}

  @override
  AiGateway get gateway => const _NullGateway();
}

class _NullGateway implements AiGateway {
  const _NullGateway();

  @override
  Future<Map<String, dynamic>?> json({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  }) async => null;

  @override
  Stream<String> stream({
    required String instructions,
    required String input,
  }) => Stream.error(StateError('AI 가 연결되지 않았어요'));
}
