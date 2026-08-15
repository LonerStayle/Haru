import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/app.dart';
import 'src/features/calendar/calendar_providers.dart';
import 'src/app/env.dart';
import 'src/core/perf.dart';
import 'src/data/remote/supabase_provider.dart';

Future<void> main() async {
  // 콜드 스타트 stopwatch 시작 — 첫 lazy 접근이 init 트리거. ensureInitialized 보다 먼저.
  ColdStartProbe.instance;

  WidgetsFlutterBinding.ensureInitialized();

  final envDiag = Env.diagnostics();
  if (envDiag != null) {
    debugPrint('[solo_todo] $envDiag');
  }

  await initSupabaseFromEnv();

  runApp(
    ProviderScope(
      // 설정 화면의 "지금 동기화" 실행부를 주입한다. 화면(C2)은 실행부를 모른 채
      // 자리만 잡아두고, 여기서 스케줄러를 물려 버튼이 살아난다.
      overrides: [calendarSyncNowOverride],
      child: const SoloTodoApp(),
    ),
  );

  // 첫 frame 렌더 완료 시점에 cold start 측정 마감 + 60fps 감시 시작.
  scheduleColdStartCapture();
  FpsMonitor.instance.start();
}
