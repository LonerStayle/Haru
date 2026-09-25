import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// E2E 드라이버 — 기기에서 찍은 화면(reportData['shots'], base64 PNG)을 호스트에 저장.
///
/// 저장 위치: 환경변수 E2E_SHOTS_OUT (기본 build/e2e_shots).
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final shots = (data?['shots'] as Map?) ?? const {};
    final dir = Platform.environment['E2E_SHOTS_OUT'] ?? 'build/e2e_shots';
    Directory(dir).createSync(recursive: true);
    for (final e in shots.entries) {
      File(
        '$dir/${e.key}.png',
      ).writeAsBytesSync(base64Decode(e.value as String));
    }
    stdout.writeln('E2E shots: ${shots.length} → $dir');
  },
);
