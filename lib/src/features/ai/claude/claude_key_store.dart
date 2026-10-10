import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Anthropic API 키 저장소. 기기별 — 동기화하지 않는다.
abstract interface class ClaudeKeyStore {
  /// 없거나 깨졌으면 null.
  Future<String?> read();

  /// 실패하면 예외 — 예외 메시지에 키를 담지 않는다.
  Future<void> write(String apiKey);

  Future<void> delete();
}

/// 평문 JSON 파일 (ChatGPT 로그인 파일과 같은 계층). `<name>.tmp` 에 쓰고 rename —
/// 쓰다 끊겨도 반쯤 쓴 키가 남지 않는다. Android 백업 대상에서 빠져 있다
/// (`backup_rules.xml`, `data_extraction_rules.xml`).
class ClaudeKeyFileStore implements ClaudeKeyStore {
  ClaudeKeyFileStore({
    this.fileName = 'ai_claude_api_key.json',
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final String fileName;
  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final dir = await _directory();
    return File(p.join(dir.path, fileName));
  }

  @override
  Future<String?> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      final key = json is Map ? json['apiKey'] : null;
      return key is String && key.isNotEmpty ? key : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String apiKey) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'apiKey': apiKey}), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete() async {
    final f = await _file();
    // .tmp 먼저 — 본 파일 지우기가 실패하면 키가 그대로 남은 상태(일관)로 끝난다.
    for (final file in [File('${f.path}.tmp'), f]) {
      if (await file.exists()) await file.delete();
    }
  }
}

/// 테스트·미리보기용 메모리 저장소.
class MemoryClaudeKeyStore implements ClaudeKeyStore {
  MemoryClaudeKeyStore([this.apiKey]);

  String? apiKey;
  int writes = 0;
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<String?> read() async => apiKey;

  @override
  Future<void> write(String apiKey) async {
    if (failWrites) throw const FileSystemException('write failed');
    writes++;
    this.apiKey = apiKey;
  }

  @override
  Future<void> delete() async {
    if (failDeletes) throw const FileSystemException('delete failed');
    apiKey = null;
  }
}
