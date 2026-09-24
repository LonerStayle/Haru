import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart';

import '../domain/category.dart';

// ----------------------------------------------------------------------------
// 1. 디자인 토큰 — 모든 위젯이 이 상수만 import 한다.
// ----------------------------------------------------------------------------

/// 간격 / 라운드 / 그림자 / 모션 등 비-컬러 토큰.
///
/// 4 의 배수 그리드를 따른다. 모든 위젯은 magic number 대신 이 토큰을 사용해야
/// 디자인 점수 § 여백·정렬 일관성이 유지된다.
class AppTokens {
  const AppTokens._();

  // spacing (4 단위)
  static const double space2 = 2;
  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;
  static const double space40 = 40;
  static const double space48 = 48;

  // radius
  static const double radiusS = 6;
  static const double radiusM = 10;
  static const double radiusL = 14;
  static const double radiusFull = 999;

  // border width
  static const double hairline = 0.5;

  // motion
  static const Duration motionFast = Duration(milliseconds: 120);
  static const Duration motionMid = Duration(milliseconds: 200);
  static const Duration motionSlow = Duration(milliseconds: 320);
}

/// 라이트/다크 라이크 톤. accent / 카테고리 색 5종은 의도적으로 토큰 밖
/// ([Category.color]) 에서 관리한다 — 도메인 의미를 시각 토큰과 묶기 위해.
class AppPalette {
  const AppPalette._();

  // Light surface
  static const Color lightBg = Color(0xFFF7F8FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceAlt = Color(0xFFF1F3F6);
  // outline 을 조금 진하게 (#E3E6EB → #D9DDE5) 카드 경계 가시성 ↑ (디자인 점수 § 대비)
  static const Color lightOutline = Color(0xFFD9DDE5);
  static const Color lightOnSurface = Color(0xFF0E1116);
  static const Color lightOnSurfaceMuted = Color(0xFF5A6273);

  // Dark surface
  static const Color darkBg = Color(0xFF101216);
  static const Color darkSurface = Color(0xFF181B22);
  static const Color darkSurfaceAlt = Color(0xFF22262F);
  static const Color darkOutline = Color(0xFF2E3340);
  static const Color darkOnSurface = Color(0xFFE9ECF1);
  static const Color darkOnSurfaceMuted = Color(0xFFA2A9B8);

  // Brand accent — 액션 / 포커스 / 선택 강조 단일 출처.
  // Category.work 와 동일 hue 지만 의미는 분리 — accent 는 "동작", category 는 "분류".
  static const Color accent = Color(0xFF2A66FF);

  /// 성공/완료 강조 (진척 100%, 연결됨 상태 점). 여러 파일에 흩어져 있던 hex 를 모았다.
  static const Color success = Color(0xFF10B981);
}

/// 메모(note) 타일 전용 시각 토큰 — task(체크 행) 와 pre-attentive 대비를 만드는
/// **단일 출처**. `TodoTile` 의 note 분기와 Outline `_NoteCard` 가 모두 이 헬퍼를
/// 공유해 모든 뷰에서 메모 시각 언어를 일관 유지한다 (§13).
///
/// 배경: 한글은 italic 글리프가 사실상 없어 기존 "제목 italic" 만으로는 메모/할 일
/// 구분이 약했다. → **카테고리색 틴트 fill + 좌측 accent 보더(3px) + "메모" 라벨** 의
/// 다른 실루엣으로 구분한다. 모든 멤버는 [BuildContext] 없이 순수 — 색 입력은
/// [Category.color] 한 곳에서만 파생한다.
class NoteVisual {
  const NoteVisual._();

  /// 좌측 accent 보더 두께 (px). leaf 메모 카드의 카테고리색 좌측 띠.
  static const double accentWidth = 3.0;

  /// "메모" 마이크로 라벨 문구.
  static const String label = '메모';

  /// 틴트 fill alpha — 다크는 어두운 surface 위라 더 진해야 같은 가시성이 난다.
  static const double tintAlphaLight = 0.08;
  static const double tintAlphaDark = 0.16;

  /// 헤딩(자식 보유 note=섹션) 틴트 alpha — leaf 보다 진해 "섹션 헤더" 로 강조(§14).
  static const double headingTintAlphaLight = 0.14;
  static const double headingTintAlphaDark = 0.24;

  /// "메모" 라벨 배경 / 외곽선 alpha (전경은 카테고리색 원색).
  static const double labelBgAlpha = 0.14;
  static const double labelOutlineAlpha = 0.50;

  /// 메모 카드 배경 틴트 (카테고리색 저알파). [brightness] 분기.
  static Color tint(Category category, Brightness brightness) =>
      category.color.withValues(
        alpha: brightness == Brightness.dark ? tintAlphaDark : tintAlphaLight,
      );

  /// 헤딩(자식 보유 note) 배경 틴트 — leaf [tint] 보다 진해 섹션 헤더로 강조.
  static Color headingTint(Category category, Brightness brightness) =>
      category.color.withValues(
        alpha: brightness == Brightness.dark
            ? headingTintAlphaDark
            : headingTintAlphaLight,
      );

  /// 좌측 accent 보더 색 — 카테고리색 원색.
  static Color accent(Category category) => category.color;

  /// "메모" 라벨 배경색.
  static Color labelBackground(Category category) =>
      category.color.withValues(alpha: labelBgAlpha);

  /// "메모" 라벨 전경(텍스트)색 — 고대비 onSurface 톤([brightness] 분기).
  ///
  /// §13-10 — 작은 라벨 텍스트에 카테고리 원색을 쓰면 warm hue(주황/초록 등)에서
  /// WCAG AA(4.5:1) 를 못 맞춘다. 카테고리 정체성은 [labelBackground]/[labelOutline]
  /// + 옆 글리프가 담당하므로, 텍스트는 모든 카테고리에서 AA 를 보장하는 onSurface 사용.
  static Color labelForeground(Brightness brightness) =>
      brightness == Brightness.dark
      ? AppPalette.darkOnSurface
      : AppPalette.lightOnSurface;

  /// "메모" 라벨 외곽선색.
  static Color labelOutline(Category category) =>
      category.color.withValues(alpha: labelOutlineAlpha);
}

// ----------------------------------------------------------------------------
// 2. ThemeData / MacosThemeData 생성기.
// ----------------------------------------------------------------------------

/// 폼팩터별 [ThemeData] (Android, Material) · [MacosThemeData] (macOS) 생성기.
class AppTheme {
  const AppTheme._();

  // 하위 호환 (기존 코드의 magic number) — 새 코드는 AppTokens 를 직접 사용.
  static const double spaceXs = AppTokens.space4;
  static const double spaceS = AppTokens.space8;
  static const double spaceM = AppTokens.space16;
  static const double spaceL = AppTokens.space24;
  static const double radiusS = AppTokens.radiusS;
  static const double radiusM = AppTokens.radiusM;

  // --- mobile (Material 3) -----------------------------------------------

  static ThemeData mobileLight() => _buildMobile(Brightness.light);
  static ThemeData mobileDark() => _buildMobile(Brightness.dark);

  static ThemeData _buildMobile(Brightness b) {
    final isLight = b == Brightness.light;
    final bg = isLight ? AppPalette.lightBg : AppPalette.darkBg;
    final surface = isLight ? AppPalette.lightSurface : AppPalette.darkSurface;
    final surfaceAlt = isLight
        ? AppPalette.lightSurfaceAlt
        : AppPalette.darkSurfaceAlt;
    final outline = isLight ? AppPalette.lightOutline : AppPalette.darkOutline;
    final onSurface = isLight
        ? AppPalette.lightOnSurface
        : AppPalette.darkOnSurface;

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      scaffoldBackgroundColor: bg,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: AppPalette.accent,
            brightness: b,
          ).copyWith(
            surface: surface,
            onSurface: onSurface,
            surfaceContainerHighest: surfaceAlt,
            outline: outline,
            primary: AppPalette.accent,
          ),
      textTheme: _textTheme(b),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          side: BorderSide(color: outline, width: AppTokens.hairline),
        ),
        color: surface,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
        ),
        backgroundColor: isLight
            ? AppPalette.darkSurface
            : AppPalette.lightSurface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space12,
          vertical: AppTokens.space12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusM),
          borderSide: const BorderSide(color: AppPalette.accent, width: 1.5),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: outline,
        space: AppTokens.hairline,
        thickness: AppTokens.hairline,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusS),
        ),
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }

  static TextTheme _textTheme(Brightness b) {
    final isLight = b == Brightness.light;
    final base = isLight ? AppPalette.lightOnSurface : AppPalette.darkOnSurface;
    final muted = isLight
        ? AppPalette.lightOnSurfaceMuted
        : AppPalette.darkOnSurfaceMuted;

    TextStyle style(
      double size,
      FontWeight weight, {
      double letterSpacing = 0,
      Color? color,
      double height = 1.4,
    }) => TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color ?? base,
      letterSpacing: letterSpacing,
      height: height,
    );

    return TextTheme(
      displayLarge: style(
        32,
        FontWeight.w700,
        letterSpacing: -0.4,
        height: 1.2,
      ),
      displayMedium: style(
        28,
        FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.25,
      ),
      headlineMedium: style(
        24,
        FontWeight.w600,
        letterSpacing: -0.2,
        height: 1.3,
      ),
      titleLarge: style(20, FontWeight.w600),
      titleMedium: style(17, FontWeight.w500),
      bodyLarge: style(15, FontWeight.w400),
      bodyMedium: style(14, FontWeight.w400),
      bodySmall: style(13, FontWeight.w400, color: muted),
      labelLarge: style(14, FontWeight.w500),
      labelMedium: style(12, FontWeight.w500, color: muted),
      // labelSmall 을 명시하지 않으면 M3 기본 11sp 가 pill·breadcrumb·그룹 라벨에 쓰여
      // 가독성이 떨어진다 (UX 개선 Phase 0). 12sp 가 이 앱의 최소 글자 크기.
      labelSmall: style(12, FontWeight.w500, color: muted, height: 1.3),
    );
  }

  // --- desktop (macos_ui) ------------------------------------------------

  static MacosThemeData desktopLight() =>
      MacosThemeData.light().copyWith(primaryColor: AppPalette.accent);

  static MacosThemeData desktopDark() =>
      MacosThemeData.dark().copyWith(primaryColor: AppPalette.accent);
}
