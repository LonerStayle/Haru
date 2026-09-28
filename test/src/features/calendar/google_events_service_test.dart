import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import 'package:solo_todo/src/features/calendar/google_events_service.dart';

/// 구글 이벤트 **조회** 레이어. 네트워크는 타지 않고 매핑과 게이트만 검증한다
/// (기존 calendar_service_test 와 같은 방침 — 순수 매핑 + provider null).
void main() {
  gcal.Event event({
    String? id = 'e1',
    String? summary = '팀 미팅',
    DateTime? startTime,
    DateTime? endTime,
    DateTime? startDate,
    DateTime? endDate,
    String? status,
  }) => gcal.Event(
    id: id,
    summary: summary,
    status: status,
    start: gcal.EventDateTime(dateTime: startTime, date: startDate),
    end: gcal.EventDateTime(dateTime: endTime, date: endDate),
  );

  group('toEntry — 시각 이벤트', () {
    test('시작/종료 시각을 그대로 쓰고 종일이 아니다', () {
      final e = GoogleEventsService.toEntry(
        event(
          startTime: DateTime(2026, 8, 15, 14),
          endTime: DateTime(2026, 8, 15, 15),
        ),
      )!;
      expect(e.id, 'e1');
      expect(e.title, '팀 미팅');
      expect(e.isAllDay, isFalse);
      expect(e.startDate, DateTime(2026, 8, 15));
      expect(e.endDate, DateTime(2026, 8, 15));
      expect(e.timeAnchorAt, DateTime(2026, 8, 15, 14));
    });

    test('읽기 전용 — 드래그 불가, 완료 개념 없음', () {
      final e = GoogleEventsService.toEntry(
        event(startTime: DateTime(2026, 8, 15, 14)),
      )!;
      expect(e.isDraggable, isFalse);
      expect(e.isDone, isFalse);
      expect(e.entryKey, 'gcal:e1');
    });
  });

  group('toEntry — 종일 이벤트', () {
    test('end.date 는 exclusive 라 하루를 뺀다', () {
      // 구글은 8/10~8/12 종일을 end.date = 8/13 으로 준다.
      final e = GoogleEventsService.toEntry(
        event(startDate: DateTime(2026, 8, 10), endDate: DateTime(2026, 8, 13)),
      )!;
      expect(e.isAllDay, isTrue);
      expect(e.startDate, DateTime(2026, 8, 10));
      expect(e.endDate, DateTime(2026, 8, 12));
      expect(e.spansMultipleDays, isTrue);
    });

    test('하루짜리 종일은 단일 항목', () {
      final e = GoogleEventsService.toEntry(
        event(startDate: DateTime(2026, 8, 10), endDate: DateTime(2026, 8, 11)),
      )!;
      expect(e.startDate, DateTime(2026, 8, 10));
      expect(e.endDate, DateTime(2026, 8, 10));
      expect(e.spansMultipleDays, isFalse);
    });

    test('종일이면 timeAnchorAt 이 null (00:00 을 시각으로 승격 안 함)', () {
      final e = GoogleEventsService.toEntry(
        event(startDate: DateTime(2026, 8, 10), endDate: DateTime(2026, 8, 11)),
      )!;
      expect(e.timeAnchorAt, isNull);
    });
  });

  group('toEntry — 그릴 수 없는 이벤트는 null', () {
    test('id 없음', () {
      expect(
        GoogleEventsService.toEntry(
          event(id: null, startTime: DateTime(2026, 8, 15)),
        ),
        isNull,
      );
    });

    test('시작이 없음', () {
      expect(GoogleEventsService.toEntry(event()), isNull);
    });

    test('취소된 인스턴스는 제외 (그리면 유령이 된다)', () {
      expect(
        GoogleEventsService.toEntry(
          event(status: 'cancelled', startTime: DateTime(2026, 8, 15)),
        ),
        isNull,
      );
    });
  });

  group('toEntry — 제목', () {
    test('제목이 비면 "(제목 없음)"', () {
      final e = GoogleEventsService.toEntry(
        event(summary: '   ', startTime: DateTime(2026, 8, 15)),
      )!;
      expect(e.title, '(제목 없음)');
    });

    test('제목이 null 이어도 그린다', () {
      final e = GoogleEventsService.toEntry(
        event(summary: null, startTime: DateTime(2026, 8, 15)),
      )!;
      expect(e.title, '(제목 없음)');
    });
  });

  test('env 미설정이면 googleEventsServiceProvider 는 null (연동 비활성)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(googleEventsServiceProvider), isNull);
  });
}
