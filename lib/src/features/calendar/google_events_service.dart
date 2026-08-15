import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;

import '../calendar_view/calendar_entry.dart';
import 'google_auth_service.dart';

/// 구글 캘린더 이벤트 **조회 전용** 서비스.
///
/// 왜 `calendar_service.dart` 에 넣지 않았나 — 그 파일은 형제 워크트리
/// (`구글캘린더동기화`) 가 양방향 동기화를 위해 통째로 손볼 영역이다. 같은 파일을
/// 양쪽에서 고치면 머지 충돌이 나므로, 앱 내 캘린더 화면이 필요로 하는 "읽기" 만
/// 이 신규 파일에 담아 충돌 표면을 0 으로 만든다. 인증([CalendarAuth])만 재사용한다.
///
/// 스코프는 기존 `calendar.events` 로 충분하다 (읽기 포함) — 재동의가 필요 없다.
class GoogleEventsService {
  const GoogleEventsService(this._auth);

  final CalendarAuth _auth;

  /// `[from, to)` 범위의 primary 캘린더 이벤트.
  ///
  /// **절대 throw 하지 않는다.** 미인증 / 네트워크 실패 / 토큰 만료는 전부 빈
  /// 리스트로 떨어진다 — 구글이 안 될 때 캘린더 화면 자체가 못 쓰게 되면 안 된다.
  ///
  /// `singleEvents: true` 로 반복 이벤트를 서버가 인스턴스로 펼쳐 준다. 그래서
  /// 클라이언트에 구글용 반복 로직을 따로 두지 않는다.
  Future<List<GoogleEventEntry>> listRange(DateTime from, DateTime to) async {
    final client = await _auth.authedClient();
    if (client == null) return const [];
    try {
      final api = gcal.CalendarApi(client);
      final events = await api.events.list(
        'primary',
        timeMin: from.toUtc(),
        timeMax: to.toUtc(),
        singleEvents: true,
        orderBy: 'startTime',
        maxResults: 2500,
      );
      return [
        for (final e in events.items ?? const <gcal.Event>[]) ?toEntry(e),
      ];
    } catch (e) {
      debugPrint('[calendar] 구글 이벤트 조회 실패 (로컬만 표시): $e');
      return const [];
    } finally {
      // CalendarAuth 계약 — 반환된 client 는 호출자가 닫는다.
      client.close();
    }
  }

  /// 구글 이벤트 → 캘린더 엔트리. 그릴 수 없는 이벤트면 null.
  ///
  /// 종일 이벤트의 `end.date` 는 **exclusive** 라 하루를 빼야 화면의 마지막 날이
  /// 맞는다 (8/10~8/12 종일이면 구글은 end.date = 8/13 으로 준다).
  @visibleForTesting
  static GoogleEventEntry? toEntry(gcal.Event event) {
    final id = event.id;
    if (id == null) return null;
    // 취소된 인스턴스는 목록에 남아 있을 수 있다 — 그리면 유령이 된다.
    if (event.status == 'cancelled') return null;

    final startDate = event.start?.date;
    final startTime = event.start?.dateTime;
    if (startDate == null && startTime == null) return null;

    final isAllDay = startDate != null;
    final start = (startTime ?? startDate)!.toLocal();

    final endDate = event.end?.date;
    final endTime = event.end?.dateTime;
    var end = (endTime ?? endDate)?.toLocal() ?? start;
    if (isAllDay && endDate != null) {
      end = DateTime(end.year, end.month, end.day - 1);
    }

    return GoogleEventEntry(
      id: id,
      title: (event.summary ?? '').trim().isEmpty
          ? '(제목 없음)'
          : event.summary!.trim(),
      start: start,
      end: end,
      isAllDay: isAllDay,
    );
  }
}

/// 인증이 구성돼 있을 때만 non-null.
final googleEventsServiceProvider = Provider<GoogleEventsService?>((ref) {
  final auth = ref.watch(calendarAuthProvider);
  return auth == null ? null : GoogleEventsService(auth);
});
