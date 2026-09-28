import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../features/category/add_category_dialog.dart';
import '../../features/category/add_group_dialog.dart';

/// 사이드바(데스크탑) / 관리 Drawer(모바일) 하단의 "카테고리 추가 · 그룹 추가" 버튼 줄.
///
/// UX 개선 Phase 0 — FAB / Cmd+N 이 곧바로 새 할 일을 열게 바뀌면서, 예전 "무엇을
/// 추가할까요?" 시트에 있던 카테고리·그룹 추가 동선을 목록 바로 아래로 옮겼다.
/// 추가 대상(카테고리·그룹)이 보이는 자리에 추가 버튼이 있어야 찾기 쉽다.
class AddEntityButtons extends StatelessWidget {
  const AddEntityButtons({super.key, this.onAdded});

  /// 다이얼로그가 저장으로 닫혔을 때 호출 (Drawer 닫기 등). 선택.
  final VoidCallback? onAdded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextButton.styleFrom(
      foregroundColor: scheme.onSurface.withValues(alpha: 0.72),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.space12,
        vertical: AppTokens.space8,
      ),
    );
    // 세로로 쌓는다 — 사이드바(220px)에서 가로 두 칸이면 "카테고리" 가 두 줄로 깨진다.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.space8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton.icon(
            key: const ValueKey('add-category-button'),
            style: style,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('카테고리 추가'),
            onPressed: () async {
              final added = await AddCategoryDialog.show(context);
              if (added == true) onAdded?.call();
            },
          ),
          TextButton.icon(
            key: const ValueKey('add-group-button'),
            style: style,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('그룹 추가'),
            onPressed: () async {
              final added = await AddGroupDialog.show(context);
              if (added == true) onAdded?.call();
            },
          ),
        ],
      ),
    );
  }
}
