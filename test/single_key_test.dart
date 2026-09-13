import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_page.dart';

/// 单一大键状态机：单击 开始 → 暂停 → 继续；长按蓄力 1.5 秒结束并结算；
/// 蓄力不满松手不结算。
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

  TimerStatus statusOf(ProviderContainer c) =>
      c.read(timerEngineProvider).statusAt(DateTime.now());

  testWidgets('单击循环：开始 → 暂停 → 继续', (WidgetTester tester) async {
    final ProviderContainer c = await pumpPage(tester);
    expect(find.text('开始'), findsOneWidget);

    // 开始
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    expect(statusOf(c), TimerStatus.running);
    expect(find.text('暂停 · 长按结束'), findsOneWidget);

    // 暂停
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    expect(statusOf(c), TimerStatus.paused);
    expect(find.text('继续 · 长按结束'), findsOneWidget);

    // 继续
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    expect(statusOf(c), TimerStatus.running);
  });

  testWidgets('长按满 1.5 秒：结束并回到空闲', (WidgetTester tester) async {
    final ProviderContainer c = await pumpPage(tester);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 400));
    expect(statusOf(c), TimerStatus.running);

    // 按住 1.5 秒蓄满。
    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.pause_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 60)); // 让按下事件进手势竞技场
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 300));
    await hold.up();
    await tester.pump(const Duration(milliseconds: 600));

    expect(statusOf(c), TimerStatus.idle, reason: '蓄满应结束当前一轮');
    expect(find.text('开始'), findsOneWidget, reason: '回到空闲态');
  });

  testWidgets('长按不足 1.5 秒：松手不结束，回到运行', (WidgetTester tester) async {
    final ProviderContainer c = await pumpPage(tester);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 400));

    // 只按 1 秒就松手。
    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.pause_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 800));
    await hold.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(statusOf(c), TimerStatus.running, reason: '蓄力未满不应结算');
  });

  testWidgets('空闲态长按不启动蓄力（不会误结算）', (WidgetTester tester) async {
    final ProviderContainer c = await pumpPage(tester);
    expect(statusOf(c), TimerStatus.idle);

    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.play_arrow_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 300));
    await hold.up();
    await tester.pump(const Duration(milliseconds: 400));

    expect(statusOf(c), TimerStatus.idle, reason: '空闲态长按不应改变状态');
  });
}
