import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sweetie_countdown/main.dart';
import 'package:sweetie_countdown/reading/favorites_page.dart';
import 'package:sweetie_countdown/reading/reading_service.dart';
import 'package:sweetie_countdown/stats/focus_record.dart';
import 'package:sweetie_countdown/stats/stats_logic.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';

/// 防回归：打开「自定义标签」弹窗并弹出软键盘时，不得出现 RenderFlex overflow。
///
/// 关键背景（曾两次踩坑）：
/// - 溢出不在弹窗，而在**背景的专注页**：键盘把页面挤扁后，
///   表盘(264)+按钮组(~118) 是固定高度、压不动，于是 RenderFlex 溢出并在屏上画黄黑条纹。
/// - TimerPage 真实运行在 [SweetieHomeShell] 的 Scaffold **之内**（嵌套 Scaffold）：
///   外层 Scaffold 若按默认 `resizeToAvoidBottomInset: true` 压缩 body，内层页面再修也没用。
///   所以本测试直接渲染**真实主壳**，而不是复刻结构。
///
/// 键盘用 `viewInsets.bottom` 模拟（测试环境 3x 像素比，900px ≈ 300dp 键盘）。
void main() {
  testWidgets('主壳内打开自定义标签弹窗 + 键盘弹出：无布局溢出', (WidgetTester tester) async {
    // 用接近真机的窗口（360dp × 800dp）：默认测试窗口只有 600dp 高，
    // 本身就可能装不下页面，会把"尺寸问题"误报成"键盘问题"。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          // 标签存储走内存，避免依赖 Hive。
          tagStoreProvider.overrideWithValue(
            TagStore(MemoryTagStorage(), defaultTags: const <String>['专注']),
          ),
          // 阅读页与统计页用最轻量的桩数据，避免真实网络与 Hive 依赖。
          readingArticleProvider.overrideWith(
            (Ref ref) => Future<ReadingArticle>.error(StateError('test stub')),
          ),
          focusRecordsProvider.overrideWith(
            (Ref ref) => Stream<List<FocusRecord>>.value(const <FocusRecord>[]),
          ),
          // 阅读页顶栏的徽标会读收藏列表（Hive），同样换成内存桩。
          favoritesProvider.overrideWith(
            (Ref ref) => Future<List<ReadingArticle>>.value(
              const <ReadingArticle>[],
            ),
          ),
        ],
        child: MaterialApp(
          theme: SweetieTheme.toThemeData(),
          home: const SweetieHomeShell(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '初始渲染不应有异常');

    // 打开「自定义标签」弹窗。
    await tester.tap(find.text('自定义'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget, reason: '弹窗应已打开');

    // 软键盘弹出。
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pump(const Duration(milliseconds: 400));
    final Object? keyboardException = tester.takeException();
    if (keyboardException is FlutterError) {
      // 打印完整诊断：定位究竟是哪棵 Flex 溢出。
      // ignore: avoid_print
      print(keyboardException.toStringDeep());
      debugDumpRenderTree();
    }
    expect(
      keyboardException,
      isNull,
      reason: '键盘弹出时（弹窗 + 背景页）都不应出现 overflow 异常',
    );

    // 键盘收起，复位。
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull, reason: '收起键盘后不应有异常');
  });
}
