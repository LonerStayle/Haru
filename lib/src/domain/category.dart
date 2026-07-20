import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'category.freezed.dart';
part 'category.g.dart';

/// Solo Todo 의 카테고리.
///
/// v1.0~v1.1 의 5 종 고정 enum 이었지만, v1.2 부터 DB row 로 저장되어 사용자가
/// 추가 / 삭제 가능한 데이터 클래스로 변환되었다. 5 builtin (work / personal_dev
/// / daily / longterm / idea) 은 [builtinSeeds] 로 static 노출되어 기존 사용처
/// (`Category.work` 등) 와 그대로 호환된다.
///
/// 필드:
/// - [id] — DB / JSON 안정 키. enum 이름이 아닌 이 값을 직렬화 키로 쓴다.
/// - [label] — 사용자에게 보여줄 한글 라벨.
/// - [iconCodePoint] — Material Icons 폰트의 codepoint (Drift / Supabase int 컬럼).
/// - [colorValue] — `Color.value` 정수 표현 (예: `0xFF2A66FF`).
/// - [sortOrder] — sidebar / outline 정렬 키 (작은 값 먼저). 기본 0.
/// - [isBuiltin] — 5 builtin 인지 사용자 정의인지 표시. 삭제 정책은 같지만,
///   향후 UX (예: builtin 만 다른 색) 분기에 쓸 수 있다.
/// - [groupId] — 소속 그룹 [Group.id]. null = '미분류' (사이드바 최상단 섹션).
///   builtin 5종은 모두 null 로 시작 (사용자가 '그룹 이동' 으로 배정). 역호환:
///   기존 JSON / Supabase row 에 group_id 가 없으면 null 로 디코드된다.
/// - [archived] — 보관 여부. true 면 사이드바/탭/오늘/타임라인/전체보기에서 숨겨지고
///   그 카테고리의 할 일도 함께 숨는다 (데이터는 보존, 설정 > 보관함에서 복원 가능).
///   삭제와 달리 할 일이 남아 있어도 보관 가능. 역호환: 기존 row 에 archived 가
///   없으면 false 로 디코드된다. builtin 5종도 보관 가능.
@freezed
abstract class Category with _$Category {
  const Category._();

  const factory Category({
    required String id,
    required String label,
    required int iconCodePoint,
    required int colorValue,
    @Default(0) int sortOrder,
    @Default(false) bool isBuiltin,
    @Default(null) String? groupId,
    @Default(false) bool archived,
  }) = _Category;

  factory Category.fromJson(Map<String, dynamic> json) =>
      _$CategoryFromJson(json);

  /// 시각화용 [Color]. [colorValue] 를 [Color] 인스턴스로 감싼다.
  Color get color => Color(colorValue);

  /// 시각화용 [IconData]. Material Icons 폰트 family 고정.
  /// 동적 codepoint 라 non-const — 빌드는 --no-tree-shake-icons 전제.
  // ignore: non_const_argument_for_const_parameter
  IconData get icon => IconData(iconCodePoint, fontFamily: 'MaterialIcons');

  /// 키보드 단축 (`1`~`5`) 으로 카테고리 전환할 때 쓰는 위치 (1-based).
  /// builtin 5종에 대해서만 의미가 있고, 사용자 정의 카테고리는 sidebar 의
  /// 동적 단축키 매핑에서 별도 처리한다 (v1.2 sidebar dynamic task).
  int get shortcutDigit => builtinSeeds.indexOf(this) + 1;

  // ===== builtin 5 종 =====
  //
  // codepoint 값은 Flutter 의 `Icons.xxx_outlined` 정의값을 그대로 사용한다
  // (icons.dart 에서 const 추출 — 'MaterialIcons' fontFamily 공통).

  static const Category work = Category(
    id: 'work',
    label: '회사 할일',
    iconCodePoint: 0xef0a, // business_center_outlined
    colorValue: 0xFF2A66FF,
    sortOrder: 0,
    isBuiltin: true,
  );

  static const Category personalDev = Category(
    id: 'personal_dev',
    label: '개인개발',
    iconCodePoint: 0xe176, // code
    colorValue: 0xFF8B5CF6,
    sortOrder: 1,
    isBuiltin: true,
  );

  static const Category daily = Category(
    id: 'daily',
    label: '일상',
    iconCodePoint: 0xf107, // home_outlined
    colorValue: 0xFF10B981,
    sortOrder: 2,
    isBuiltin: true,
  );

  static const Category longterm = Category(
    id: 'longterm',
    label: '장기 목표',
    iconCodePoint: 0xf07b, // flag_outlined
    colorValue: 0xFFEF4444,
    sortOrder: 3,
    isBuiltin: true,
  );

  static const Category idea = Category(
    id: 'idea',
    label: '아이디어',
    iconCodePoint: 0xe37c, // lightbulb_outline
    colorValue: 0xFFF59E0B,
    sortOrder: 4,
    isBuiltin: true,
  );

  /// 5 builtin 의 const 리스트. Drift onCreate / migration 시 seed 로 사용.
  static const List<Category> builtinSeeds = [
    work,
    personalDev,
    daily,
    longterm,
    idea,
  ];

  /// 기존 enum 의 `Category.values` 호환 alias. v1.2 sidebar 가 동적
  /// destination 으로 바뀌면 호출처가 줄어든다.
  static const List<Category> values = builtinSeeds;

  /// 저장된 [id] 로부터 카테고리를 복원. 미지 id 는 [ArgumentError].
  static Category fromId(String id) {
    return builtinSeeds.firstWhere(
      (c) => c.id == id,
      orElse: () => throw ArgumentError('Unknown category id: $id'),
    );
  }

  /// [Category.fromId] 의 safe 버전. 미지 id 면 null 반환.
  static Category? tryFromId(String id) {
    for (final c in builtinSeeds) {
      if (c.id == id) return c;
    }
    return null;
  }
}
