import 'package:flutter/material.dart';

/// 甜系番茄钟调色板：背景 #FFFDF9 / 粉 #FF8595 / 黄 #FFE082 / 绿 #A8E6CF / 字 #4A4A4A。
class SweetieColors {
  const SweetieColors._();

  static const Color background = Color(0xFFFFFDF9);
  static const Color pink = Color(0xFFFF8595);
  static const Color yellow = Color(0xFFFFE082);
  static const Color green = Color(0xFFA8E6CF);
  static const Color text = Color(0xFF4A4A4A);
  static const Color textLight = Color(0xFF9B9B9B);
  static const Color white = Color(0xFFFFFFFF);

  /// 马卡龙三色轮转，给页面元素挑一个“不重样”的柔和配色。
  static const List<Color> macarons = <Color>[pink, yellow, green];

  /// 12% 透明度的同色浅底，用作胶囊/徽标/选中态背景。
  static Color soft(Color color) => color.withValues(alpha: 0.12);
}

/// 主题工厂：圆角 24、彩色阴影、马卡龙按钮与卡片。入口是 [toThemeData]。
class SweetieTheme {
  const SweetieTheme._();

  static const double radius = 24;
  static const double pillRadius = 999;
  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(radius));

  /// 甜系动画节奏：回弹式缓动。
  static const Duration animationDuration = Duration(milliseconds: 320);
  static const Curve animationCurve = Curves.easeOutBack;

  /// 彩色阴影：用同色调低透明度光晕替代灰黑投影。
  static List<BoxShadow> cardShadow([Color color = SweetieColors.pink]) {
    return <BoxShadow>[
      BoxShadow(
        color: color.withValues(alpha: 0.20),
        blurRadius: 18,
        offset: const Offset(0, 8),
      ),
    ];
  }

  /// 按钮/胶囊选中态的更强光晕。
  static List<BoxShadow> buttonShadow([Color color = SweetieColors.pink]) {
    return <BoxShadow>[
      BoxShadow(
        color: color.withValues(alpha: 0.38),
        blurRadius: 16,
        offset: const Offset(0, 6),
      ),
    ];
  }

  static ThemeData toThemeData() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: SweetieColors.pink,
      brightness: Brightness.light,
    ).copyWith(
      primary: SweetieColors.pink,
      secondary: SweetieColors.yellow,
      tertiary: SweetieColors.green,
      surface: SweetieColors.background,
      onSurface: SweetieColors.text,
      onPrimary: SweetieColors.white,
      onSecondary: SweetieColors.text,
      onTertiary: SweetieColors.text,
    );

    final TextTheme base = Typography.material2021().black.apply(
          bodyColor: SweetieColors.text,
          displayColor: SweetieColors.text,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: SweetieColors.background,
      canvasColor: SweetieColors.background,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      textTheme: base.copyWith(
        headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
        titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
        bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: SweetieColors.text,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: SweetieColors.text,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: SweetieColors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SweetieColors.pink,
          foregroundColor: SweetieColors.white,
          disabledBackgroundColor: SweetieColors.textLight.withValues(alpha: 0.25),
          disabledForegroundColor: SweetieColors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: SweetieColors.text,
          side: const BorderSide(color: SweetieColors.pink, width: 2),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: SweetieColors.pink,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        ),
      ),
      iconTheme: const IconThemeData(color: SweetieColors.text),
      dividerTheme: DividerThemeData(
        color: SweetieColors.textLight.withValues(alpha: 0.20),
        thickness: 1,
        space: 24,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: SweetieColors.soft(SweetieColors.pink),
        selectedColor: SweetieColors.pink,
        labelStyle: const TextStyle(color: SweetieColors.text, fontWeight: FontWeight.w600),
        secondaryLabelStyle: const TextStyle(color: SweetieColors.white, fontWeight: FontWeight.w600),
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        side: BorderSide.none,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: SweetieColors.white,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        titleTextStyle: const TextStyle(
          color: SweetieColors.text,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(color: SweetieColors.text, fontSize: 15, height: 1.5),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: SweetieColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: SweetieColors.text,
        contentTextStyle: const TextStyle(color: SweetieColors.white, fontWeight: FontWeight.w600),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: SweetieColors.pink,
        inactiveTrackColor: SweetieColors.soft(SweetieColors.pink),
        thumbColor: SweetieColors.white,
        overlayColor: SweetieColors.soft(SweetieColors.pink),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: SweetieColors.pink,
        linearTrackColor: Color(0xFFFFE3E7),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: SweetieColors.text,
        textColor: SweetieColors.text,
        shape: RoundedRectangleBorder(borderRadius: cardRadius),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: SweetieColors.text,
        unselectedLabelColor: SweetieColors.textLight,
        indicatorColor: SweetieColors.pink,
        dividerColor: Colors.transparent,
      ),
    );
  }
}
