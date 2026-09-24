import 'package:flutter/material.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../domain/group.dart';
import '../home/home_screen.dart';
import '../outline/outline_screen.dart';

/// 그룹 단위 화면 (A안) — 상단 `[오늘 | 전체보기]` 탭으로 **그 그룹 안의 할 일만** 본다.
///
/// - **오늘** 탭: 그 그룹 카테고리의 오늘 할 일 ([HomeScreen] 을 그룹 필터로 재사용).
/// - **전체보기** 탭: 그 그룹의 카테고리 → 태스크 트리(+메모). 그룹 헤더 없이 평면으로
///   ([OutlineScreen] 을 그룹 필터로 재사용 — 내부 체크리스트/메모 하위 탭 유지).
///
/// 전역 '오늘' / '전체보기' destination 과는 별개의 화면이다. 사이드바에서 그룹 헤더를
/// 탭하거나, 모바일 관리 Drawer 에서 그룹을 탭하면 진입한다.
class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.group});

  final Group group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      initialIndex: 1, // 디폴트 = '전체보기' 탭
      child: Column(
        children: [
          // 모바일은 앱바가 그룹 이름을 보여 주므로 본문 제목 줄은 데스크탑만.
          if (!AppPlatform.isMobile)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.space24,
                AppTokens.space32,
                AppTokens.space24,
                AppTokens.space12,
              ),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 16, color: group.color),
                  const SizedBox(width: AppTokens.space12),
                  Expanded(
                    child: Text(
                      group.label,
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.space16),
            child: TabBar(
              key: ValueKey('group-tabs'),
              tabs: [
                Tab(text: '오늘'),
                Tab(text: '전체보기'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                HomeScreen(group: group, showHeader: false),
                OutlineScreen(group: group, showHeader: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
