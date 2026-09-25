import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/core/ui_prefs.dart';

class _SlowStore extends MemoryUiPrefsStore {
  @override
  Future<Set<String>> loadIds(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return super.loadIds(key);
  }
}

void main() {
  test('저장된 집합을 복원한다', () async {
    final store = MemoryUiPrefsStore()..data['k'] = {'a', 'b'};
    final c = ProviderContainer(
      overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    c.read(persistedIdSetProvider('k'));
    await c.read(persistedIdSetProvider('k').notifier).restored;
    expect(c.read(persistedIdSetProvider('k')), {'a', 'b'});
  });

  test('복원 전에 바꾼 것은 저장값 위에 얹힌다 (다른 저장값을 지우지 않음)', () async {
    final store = _SlowStore()..data['k'] = {'b', 'c'};
    final c = ProviderContainer(
      overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    final n = c.read(persistedIdSetProvider('k').notifier);
    n.toggle('a'); // 복원 전
    await n.restored;
    await Future<void>.delayed(Duration.zero);

    expect(c.read(persistedIdSetProvider('k')), {'a', 'b', 'c'});
    expect(store.data['k'], {'a', 'b', 'c'});
  });

  test('토글은 바로 저장된다', () async {
    final store = MemoryUiPrefsStore();
    final c = ProviderContainer(
      overrides: [uiPrefsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    final n = c.read(persistedIdSetProvider('k').notifier);
    await n.restored;
    n.toggle('x');
    await Future<void>.delayed(Duration.zero);
    expect(store.data['k'], {'x'});
    n.toggle('x');
    await Future<void>.delayed(Duration.zero);
    expect(store.data['k'], <String>{});
  });
}
