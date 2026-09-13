import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_page.dart';

/// 甜系滚轮时长面板：三列滚轮（时/分/秒）+ 快捷预设 + 全零禁用。
void main() {
  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: <Override>[
        tagStoreProvider.overrideWithValue(
          TagStore(MemoryTagStorage(), defaultTags: const <String>['专注']),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SweetieTheme.toThemeData(),
          home: const TimerPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    return container;
  }

  Future<void> openSheet(WidgetTester tester, {String clock = '25:00'}) async {
    // 点表盘中央的时间文本打开时长面板（文本随当前时长变化）。
    await tester.tap(find.text(clock));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('面板打开：三列滚轮 + 确认按钮', (WidgetTester tester) async {
    await pumpPage(tester);
    await openSheet(tester);

    expect(find.text('倒计时时长'), findsOneWidget);
    expect(find.byType(ListWheelScrollView), findsNWidgets(3), reason: '时/分/秒 三列');
    expect(find.text('时'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);
    expect(find.text('秒'), findsOneWidget);
    expect(find.text('确认设定'), findsOneWidget);
  });

  testWidgets('快捷预设：点「15 分钟 · 偷闲」滚轮对齐并更新大字',
      (WidgetTester tester) async {
    await pumpPage(tester);
    await openSheet(tester);

    await tester.tap(find.text('15 分钟 · 偷闲'));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('00 : 15 : 00'), findsOneWidget, reason: '大字应显示 00:15:00');
  });

  testWidgets('全零：确认按钮禁用并提示', (WidgetTester tester) async {
    final ProviderContainer container = await pumpPage(tester);
    // 先把时长调成 5 秒，方便把秒列滚回 0。
    container.read(timerEngineProvider.notifier).setDuration(
          const Duration(seconds: 5),
        );
    await tester.pump(const Duration(milliseconds: 200));

    await openSheet(tester, clock: '00:05');
    expect(find.text('确认设定'), findsOneWidget);

    // 秒列向下拖 5 格（itemExtent 44 × 5），回到 00。
    await tester.drag(
      find.byType(ListWheelScrollView).at(2),
      const Offset(0, 44 * 5),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('至少选 1 秒'), findsOneWidget, reason: '全零时按钮文案切换');
    final FilledButton button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '至少选 1 秒'),
    );
    expect(button.onPressed, isNull, reason: '全零时确认按钮应禁用（虚化）');
  });
}
