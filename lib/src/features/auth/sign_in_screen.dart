import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'auth_error_message.dart';
import 'auth_service.dart';

/// 이메일 OTP 코드 흐름. 두 단계:
///   1) 이메일 입력 → "코드 받기" → 코드 발송
///   2) 코드 입력 → "확인" → 세션 생성 (코드 길이는 Supabase 설정에 따라 6~10자리라
///      화면 문구에 자릿수를 쓰지 않는다)
///
/// 매직링크가 아니라 OTP — Supabase Site URL 이 다른 앱과 공유 불가능한 제약을 우회.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

enum _Step { email, otp }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _emailCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;

  /// OTP 자동 verify debounce timer — 사용자가 입력을 멈춘 후 [_autoVerifyDelay] 가
  /// 지나면 자동으로 [_verify] 호출. 빠르게 6→10자리 모두 입력하는 동안에는 매 keystroke
  /// 마다 cancel + 재설정되어 중간 길이 (예: 6) 에서 잘못 fire 하지 않는다.
  Timer? _autoVerifyTimer;

  /// 디바운스 길이 — 입력 후 잠깐 멈췄음을 인지하기엔 충분히 짧고, 빠른 8자리 타이핑
  /// 도중 중간 fire 되기엔 충분히 길다.
  static const Duration _autoVerifyDelay = Duration(milliseconds: 300);

  /// 코드 다시 받기까지 남은 초 — Supabase 는 1분에 한 번만 보내 준다.
  int _resendIn = 0;
  Timer? _resendTimer;
  static const int _resendCooldown = 60;

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = _resendCooldown);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _resendIn = _resendIn > 0 ? _resendIn - 1 : 0);
      if (_resendIn == 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _autoVerifyTimer?.cancel();
    _resendTimer?.cancel();
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  bool get _canSendEmail {
    final v = _emailCtrl.text.trim();
    return v.contains('@') && v.length >= 5 && !_busy;
  }

  /// Supabase 의 OTP length 가 프로젝트 설정에 따라 6~10 가변이므로 6 이상만 검사.
  bool get _canVerify => _otpCtrl.text.trim().length >= 6 && !_busy;

  Future<void> _sendCode() async {
    final auth = ref.read(authServiceProvider);
    if (auth == null || !_canSendEmail) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.sendEmailOtp(_emailCtrl.text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _Step.otp;
      });
      _startResendCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyAuthErrorMessage(e, forVerify: false);
      });
    }
  }

  Future<void> _verify() async {
    final auth = ref.read(authServiceProvider);
    if (auth == null || !_canVerify) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.verifyEmailOtp(email: _emailCtrl.text, token: _otpCtrl.text);
      // 성공 시 authStateProvider 가 signedIn emit → _AuthGate 가 AppShell 로 전환.
      // 별도 navigation 불필요.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyAuthErrorMessage(e, forVerify: true);
      });
    }
  }

  /// 코드 다시 받기 — 같은 이메일로 새 코드.
  Future<void> _resend() async {
    final auth = ref.read(authServiceProvider);
    if (auth == null || _busy || _resendIn > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.sendEmailOtp(_emailCtrl.text);
      if (!mounted) return;
      _otpCtrl.clear();
      setState(() => _busy = false);
      _startResendCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('새 코드를 보냈어요'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyAuthErrorMessage(e, forVerify: false);
      });
    }
  }

  void _backToEmail() {
    _autoVerifyTimer?.cancel();
    setState(() {
      _step = _Step.email;
      _otpCtrl.clear();
      _error = null;
    });
  }

  /// OTP TextField onChanged 콜백. 입력 길이가 6 이상이면 [_autoVerifyDelay] 후 자동
  /// verify. Supabase OTP 길이는 6~10 가변이라 정확한 길이를 client 가 모르므로
  /// 디바운스로 사용자가 입력을 멈출 때까지 기다리는 방식.
  void _onOtpChanged(String value) {
    setState(() {});
    _autoVerifyTimer?.cancel();
    if (value.trim().length >= 6 && !_busy) {
      _autoVerifyTimer = Timer(_autoVerifyDelay, () {
        if (mounted && _canVerify) _verify();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.space24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.asset(
                        'assets/branding/app_icon_256.png',
                        key: const ValueKey('sign-in-brand'),
                        width: 64,
                        height: 64,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.check_circle_outline_rounded,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTokens.space16),
                  Text(
                    '하루',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppTokens.space8),
                  Text(
                    _step == _Step.email
                        ? '이메일로 로그인 코드를 보내 드릴게요.'
                        : '메일로 받은 코드를 입력해 주세요.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppTokens.space24),
                  // 오류는 입력칸 바로 아래(errorText)에 — 무엇이 문제인지 칸과 함께 보이게.
                  if (_step == _Step.email)
                    ..._emailFields(theme)
                  else
                    ..._otpFields(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _emailFields(ThemeData theme) {
    return [
      TextField(
        controller: _emailCtrl,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        autofocus: true,
        enabled: !_busy,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _sendCode(),
        decoration: InputDecoration(
          hintText: 'you@example.com',
          prefixIcon: const Icon(Icons.email_outlined),
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      const SizedBox(height: AppTokens.space12),
      FilledButton(
        onPressed: _canSendEmail ? _sendCode : null,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.space12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
          ),
        ),
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('코드 받기'),
      ),
    ];
  }

  List<Widget> _otpFields(ThemeData theme) {
    return [
      Container(
        padding: const EdgeInsets.all(AppTokens.space12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
        ),
        child: Row(
          children: [
            Icon(
              Icons.mark_email_read_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: AppTokens.space12),
            Expanded(
              child: Text(
                '${_emailCtrl.text.trim()} 으로 코드를 보냈어요',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppTokens.space12),
      TextField(
        controller: _otpCtrl,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        autofocus: true,
        enabled: !_busy,
        maxLength: 10,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: _onOtpChanged,
        onSubmitted: (_) => _verify(),
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineMedium?.copyWith(
          letterSpacing: 6,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          hintText: '코드 입력',
          counterText: '',
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      const SizedBox(height: AppTokens.space12),
      FilledButton(
        onPressed: _canVerify ? _verify : null,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: AppTokens.space12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTokens.radiusM),
          ),
        ),
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('확인'),
      ),
      const SizedBox(height: AppTokens.space8),
      // 좁은 폭(312)에선 두 버튼이 한 줄에 안 들어간다 — 넘치면 줄바꿈.
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          TextButton(
            key: const ValueKey('sign-in-resend'),
            onPressed: _busy || _resendIn > 0 ? null : _resend,
            child: Text(_resendIn > 0 ? '코드 다시 받기 ($_resendIn초)' : '코드 다시 받기'),
          ),
          TextButton(
            onPressed: _busy ? null : _backToEmail,
            child: const Text('다른 이메일로'),
          ),
        ],
      ),
    ];
  }
}
