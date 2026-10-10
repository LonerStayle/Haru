import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'siwc_account.dart';

/// ChatGPT 로그인 정보 저장소. 기기별 — 동기화하지 않는다.
abstract interface class SiwcStore {
  /// 없거나 깨졌으면 빈 값.
  Future<SiwcStoreData> read();

  /// 실패하면 예외 — 호출자는 메모리 값을 유지한다.
  Future<void> write(SiwcStoreData data);
}

/// 평문 JSON 파일 저장 (하루 Microsoft·Google 토큰 파일과 같은 계층).
///
/// Microsoft 저장과 다른 점: **원자적 쓰기** — `<name>.tmp` 에 쓰고 rename.
/// SIWC 는 갱신마다 refresh 가 회전하므로, 쓰다 끊겨 파일이 깨지면 다음 갱신이
/// `refresh_token_reused` 로 계열 전체가 무효화된다.
class SiwcFileStore implements SiwcStore {
  SiwcFileStore({
    this.fileName = 'ai_chatgpt_accounts.json',
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final String fileName;
  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final dir = await _directory();
    return File(p.join(dir.path, fileName));
  }

  @override
  Future<SiwcStoreData> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const SiwcStoreData();
      return SiwcStoreData.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return const SiwcStoreData();
    }
  }

  @override
  Future<void> write(SiwcStoreData data) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}

/// 테스트·미리보기용 메모리 저장소.
class MemorySiwcStore implements SiwcStore {
  MemorySiwcStore([this.data = const SiwcStoreData()]);

  SiwcStoreData data;
  int writes = 0;
  bool failWrites = false;

  @override
  Future<SiwcStoreData> read() async => data;

  @override
  Future<void> write(SiwcStoreData data) async {
    if (failWrites) throw const FileSystemException('write failed');
    writes++;
    this.data = data;
  }
}
