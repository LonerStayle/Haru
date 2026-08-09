import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/policies/todo_sort_policy.dart';
import 'package:solo_todo/src/features/settings/sort_mode_controller.dart';

/// 인메모리 저장소 — shared_preferences 플랫폼 채널 없이 테스트한다.
class _FakeStore implements SortModePreference {
  _FakeStore({this.stored = TodoSortMode.manual, Completer<void>? gate})
    : _gate = gate;

  TodoSortMode stored;
  final Completer<void>? _gate;
  int saveCount = 0;

  @override
  Future<TodoSortMode> load() async {
    if (_gate != null) await _gate.future;
    return stored;
  }

  @override
  Future<void> save(TodoSortMode mode) async {
    stored = mode;
    saveCount++;
  }
}

void main() {
  ProviderContainer containerWith(_FakeStore store) {
    final container = ProviderContainer(
      overrides: [sortModePreferenceProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('저장된 정렬 모드를 앱 시작 시 복원한다', () async {
    final store = _FakeStore(stored: TodoSortMode.dueDate);
    final container = containerWith(store);

    // 복원 전 초기값은 수동.
    expect(container.read(sortModeProvider), TodoSortMode.manual);

    await container.read(sortModeProvider.notifier).restored;

    expect(container.read(sortModeProvider), TodoSortMode.dueDate);
  });

  test('toggle 하면 모드가 바뀌고 저장된다', () async {
    final store = _FakeStore();
    final container = containerWith(store);
    await container.read(sortModeProvider.notifier).restored;

    await container.read(sortModeProvider.notifier).toggle();

    expect(container.read(sortModeProvider), TodoSortMode.dueDate);
    expect(store.stored, TodoSortMode.dueDate);
    expect(store.saveCount, 1);

    await container.read(sortModeProvider.notifier).toggle();

    expect(container.read(sortModeProvider), TodoSortMode.manual);
    expect(store.stored, TodoSortMode.manual);
  });

  test('복원이 늦게 끝나도 그 사이 사용자가 바꾼 모드를 덮어쓰지 않는다', () async {
    final gate = Completer<void>();
    final store = _FakeStore(stored: TodoSortMode.manual, gate: gate);
    final container = containerWith(store);
    final notifier = container.read(sortModeProvider.notifier);

    // 저장된 값(manual)이 도착하기 전에 사용자가 일정순으로 전환.
    await notifier.toggle();
    expect(container.read(sortModeProvider), TodoSortMode.dueDate);

    gate.complete();
    await notifier.restored;

    expect(container.read(sortModeProvider), TodoSortMode.dueDate);
  });

  test('저장소가 실패해도 앱은 수동 정렬로 계속 동작한다', () async {
    final container = ProviderContainer(
      overrides: [
        sortModePreferenceProvider.overrideWithValue(_ThrowingStore()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(sortModeProvider.notifier).restored;

    expect(container.read(sortModeProvider), TodoSortMode.manual);
    // 저장 실패도 UI 로 전파되지 않는다 (상태는 바뀐다).
    await container.read(sortModeProvider.notifier).toggle();
    expect(container.read(sortModeProvider), TodoSortMode.dueDate);
  });
}

class _ThrowingStore implements SortModePreference {
  @override
  Future<TodoSortMode> load() async => throw StateError('저장소 없음');

  @override
  Future<void> save(TodoSortMode mode) async => throw StateError('저장소 없음');
}
