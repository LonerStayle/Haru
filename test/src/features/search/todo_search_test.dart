import 'package:flutter_test/flutter_test.dart';

import 'package:solo_todo/src/domain/category.dart';
import 'package:solo_todo/src/domain/todo.dart';
import 'package:solo_todo/src/features/search/todo_search.dart';

void main() {
  Todo make({
    required String id,
    String title = 't',
    String? description,
    Category? category,
    String? parentId,
    TodoType type = TodoType.task,
    bool isSeriesMaster = false,
  }) => Todo(
    id: id,
    title: title,
    description: description,
    category: category ?? Category.work,
    dueAt: null,
    doneAt: null,
    createdAt: DateTime.utc(2026, 8, 15, 9),
    updatedAt: DateTime.utc(2026, 8, 15, 9),
    calendarEventId: null,
    parentId: parentId,
    type: type,
    isSeriesMaster: isSeriesMaster,
  );

  group('searchTodos', () {
    test('빈 검색어면 결과 없음', () {
      final all = [make(id: '1', title: '회의 준비')];
      expect(searchTodos(all: all, query: ''), isEmpty);
      expect(searchTodos(all: all, query: '   '), isEmpty);
    });

    test('제목 부분일치 — 대소문자 무시', () {
      final all = [
        make(id: '1', title: 'Deploy 서버'),
        make(id: '2', title: '장보기'),
      ];
      final hits = searchTodos(all: all, query: 'deploy');
      expect(hits.map((h) => h.todo.id), ['1']);
      // 제목만 매칭이면 발췌는 없다 (제목이 이미 타일에 보인다).
      expect(hits.single.snippet, isNull);
    });

    test('메모 본문 매칭 — 발췌를 함께 돌려준다', () {
      final all = [
        make(id: '1', title: '주간 회고', description: '다음 스프린트는 결제 모듈부터 착수'),
      ];
      final hits = searchTodos(all: all, query: '결제');
      expect(hits.map((h) => h.todo.id), ['1']);
      expect(hits.single.snippet, contains('결제'));
    });

    test('제목·메모 어디에도 없으면 제외', () {
      final all = [make(id: '1', title: '장보기', description: '우유')];
      expect(searchTodos(all: all, query: '회의'), isEmpty);
    });

    test('반복 시리즈 마스터는 검색에서 제외', () {
      final all = [
        make(id: 'master', title: '주간 회의', isSeriesMaster: true),
        make(id: 'inst', title: '주간 회의'),
      ];
      final hits = searchTodos(all: all, query: '주간');
      expect(hits.map((h) => h.todo.id), ['inst']);
    });

    test('보관된 카테고리의 항목은 제외', () {
      final all = [
        make(id: '1', title: '회의록', category: Category.work),
        make(id: '2', title: '회의록', category: Category.daily),
      ];
      final hits = searchTodos(
        all: all,
        query: '회의',
        excludedCategoryIds: {Category.daily.id},
      );
      expect(hits.map((h) => h.todo.id), ['1']);
    });

    test('완료 항목도 검색된다 — 지난 기록 찾기가 주 용도', () {
      final done = make(
        id: '1',
        title: '배포 완료',
      ).toggleDone(now: () => DateTime.utc(2026, 8, 14));
      final hits = searchTodos(all: [done], query: '배포');
      expect(hits.map((h) => h.todo.id), ['1']);
    });

    test('순위 — 제목 앞부분 > 제목 중간 > 메모만', () {
      final all = [
        make(id: 'memo', title: '무관한 제목', description: '여기에 결제 얘기'),
        make(id: 'middle', title: '신규 결제 흐름'),
        make(id: 'prefix', title: '결제 모듈 정리'),
      ];
      final hits = searchTodos(all: all, query: '결제');
      expect(hits.map((h) => h.todo.id), ['prefix', 'middle', 'memo']);
    });

    test('같은 순위 안에서는 원래 목록 순서를 유지', () {
      final all = [
        make(id: 'a', title: '결제 A'),
        make(id: 'b', title: '결제 B'),
        make(id: 'c', title: '결제 C'),
      ];
      final hits = searchTodos(all: all, query: '결제');
      expect(hits.map((h) => h.todo.id), ['a', 'b', 'c']);
    });

    test('breadcrumb — 카테고리 라벨과 상위 제목을 이어붙인다', () {
      final root = make(id: 'r', title: '넥서스');
      final child = make(id: 'c', title: '캔버스', parentId: 'r');
      final leaf = make(id: 'l', title: '결제 붙이기', parentId: 'c');
      final hits = searchTodos(all: [root, child, leaf], query: '결제');
      expect(hits.single.breadcrumb, '${Category.work.label} › 넥서스 › 캔버스');
    });

    test('breadcrumb — 최상위 항목은 카테고리 라벨만', () {
      final hits = searchTodos(
        all: [make(id: '1', title: '결제')],
        query: '결제',
      );
      expect(hits.single.breadcrumb, Category.work.label);
    });

    test('parentId 가 끊겨 있어도(동기화 race) 안전하게 멈춘다', () {
      final orphan = make(id: 'o', title: '결제', parentId: 'missing');
      final hits = searchTodos(all: [orphan], query: '결제');
      expect(hits.single.breadcrumb, Category.work.label);
    });
  });

  group('buildSnippet', () {
    test('매칭 앞뒤로만 잘라내고 잘린 쪽에 줄임표', () {
      final text = '${'가' * 60}키워드${'나' * 60}';
      final snippet = buildSnippet(text, '키워드', context: 5);
      expect(snippet, '…가가가가가키워드나나나나나…');
    });

    test('짧은 본문은 통째로 — 줄임표 없음', () {
      expect(buildSnippet('짧은 메모', '메모'), '짧은 메모');
    });

    test('줄바꿈과 연속 공백은 한 칸으로 눌러 한 줄로', () {
      expect(buildSnippet('첫 줄\n\n둘째   줄', '둘째'), '첫 줄 둘째 줄');
    });

    test('대소문자 무시로 매칭 지점을 찾는다', () {
      expect(buildSnippet('Deploy to prod', 'deploy', context: 2), 'Deploy t…');
    });
  });
}
