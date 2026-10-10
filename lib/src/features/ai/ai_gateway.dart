/// AI 단발 호출 — 기능 화면이 아는 유일한 창구.
///
/// 어느 플랜(ChatGPT / Claude)인지는 여기서 가려진다. 기능은 지시문·입력·출력 스키마만
/// 넘기고, 검증된 JSON 을 받는다.
abstract interface class AiGateway {
  /// [schema] 모양의 JSON 객체 하나를 받는다. 실패(네트워크·인증·한도·형식 불일치·
  /// 타임아웃)는 전부 null — 예외를 던지지 않는다.
  Future<Map<String, dynamic>?> json({
    required String instructions,
    required String input,
    required Map<String, dynamic> schema,
  });

  /// 텍스트 조각 스트림 (긴 답용). 실패는 스트림 error 이벤트.
  Stream<String> stream({required String instructions, required String input});
}
