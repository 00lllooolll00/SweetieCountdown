import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_page.dart';

/// 计时中锁定标签：倒计时/正计时处于「进行中」或「暂停」时，
/// 标签条必须不可点（不允许中途换 Tag，避免记录归属混乱）；
/// 空闲或刚结束时仍可自由切换。
void main() {
  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: <Override>[
        tagStoreProvider.overrideWithValue(
          TagStore(
            MemoryTagStorage(),
            defaultTags: const <String>['专注', '学习'],
          ),
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

  testWidgets('空闲时：点第二个标签可以切换', (WidgetTester tester) async {
    final ProviderContainer container = await pumpPage(tester);
    expect(container.read(selectedTagProvider), '专注');

    await tester.tap(find.text('# 学习'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(container.read(selectedTagProvider), '学习', reason: '空闲态应可自由切换');
  });

  testWidgets('倒计时进行中：点标签不切换', (WidgetTester tester) async {
    final ProviderContainer container = await pumpPage(tester);

    // 开始倒计时（点按钮圆里的播放图标；文字 label 在按钮外，点了不触发）。
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(timerEngineProvider).statusAt(DateTime.now()),
      TimerStatus.running,
      reason: '前置：倒计时已进入运行态',
    );

    // 尝试切换标签。
    await tester.tap(find.text('# 学习'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      container.read(selectedTagProvider),
      '专注',
      reason: '运行中不允许切换标签',
    );
  });

  testWidgets('正计时进行中：点标签不切换；结束后恢复可切换',
      (WidgetTester tester) async {
    final ProviderContainer container = await pumpPage(tester);

    // 切到正计时并开始。
    await tester.tap(find.text('正计时'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      container.read(timerEngineProvider).statusAt(DateTime.now()),
      TimerStatus.running,
    );

    await tester.tap(find.text('# 学习'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(selectedTagProvider), '专注', reason: '正计时运行中同样锁定');

    // 长按主键蓄力 1.5 秒结束，回到空闲后恢复可切换。
    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.pause_rounded)),
    );
    await tester.pump(const Duration(milliseconds: 60)); // 让按下事件进手势竞技场
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 200));
    await hold.up();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('# 学习'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(selectedTagProvider), '学习', reason: '结束后应恢复自由切换');
  });
}
