import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_page.dart';

/// 复现并防回归：打开「自定义标签」弹窗并弹出软键盘时，
/// 背景页面与弹窗都不得出现 RenderFlex overflow。
///
/// 键盘用 `viewInsets.bottom` 模拟（3x 设备像素比下 900px ≈ 300dp 键盘）。
void main() {
  testWidgets('打开自定义标签弹窗 + 键盘弹出：无布局溢出', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          tagStoreProvider.overrideWithValue(
            TagStore(MemoryTagStorage(), defaultTags: const <String>['专注']),
          ),
        ],
        child: MaterialApp(
          theme: SweetieTheme.toThemeData(),
          home: const TimerPage(),
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
      // 渲染树里 overflow 的 Flex 会被标注 OVERFLOWING，直接 dump 出来定位。
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
