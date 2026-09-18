import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sweetie_countdown/settings/translation_settings.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_page.dart';
import 'package:sweetie_countdown/timer/timer_session_store.dart';

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

  /// 防回归：正计时选了自定义 Tag A，后台跑久了被系统杀掉，
  /// 回来后计时轮从快照恢复，选中标签也必须跟着快照走，
  /// 不能回落到历史第一位（否则整轮记录归到错误的 Tag B）。
  test('有计时快照：选中标签从快照恢复，不回落历史第一位', () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('sweetie_tag_restore_test');
    Hive.init(tempDir.path);
    final Box<dynamic> box = await Hive.openBox<dynamic>(kSettingsBoxName);
    addTearDown(() async {
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // 杀后台前：正计时运行中，绑定 Tag A。
    final DateTime start = DateTime.now().subtract(const Duration(minutes: 30));
    await box.put(
      TimerSessionStore.sessionKey,
      jsonEncode(
        TimerSession(
          mode: 'stopwatch',
          totalMs: 0,
          startedAtMs: start.millisecondsSinceEpoch,
          pausedTotalMs: 0,
          tag: 'Tag A',
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      ),
    );

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        tagStoreProvider.overrideWithValue(
          TagStore(
            MemoryTagStorage(),
            // 故意让历史第一位是别的标签:回归时旧的回落逻辑会选中它。
            defaultTags: const <String>['Tag B', 'Tag A'],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(selectedTagProvider),
      'Tag A',
      reason: '杀后台恢复后，选中标签应跟随快照，而不是历史第一位',
    );
    expect(
      container.read(timerEngineProvider).mode,
      TimerMode.stopwatch,
      reason: '前置：计时轮本身也从快照恢复为正计时',
    );
  });

  /// 防回归：杀后台期间已到点的倒计时会被引擎补落清空(回到空闲),
  /// 标签也必须跟着回落历史第一位,不能选中快照里的 stale 标签。
  test('倒计时已到点的快照：不恢复快照标签，回落历史第一位', () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('sweetie_tag_restore_test');
    Hive.init(tempDir.path);
    final Box<dynamic> box = await Hive.openBox<dynamic>(kSettingsBoxName);
    addTearDown(() async {
      await Hive.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // 倒计时 25 分钟,杀后台期间已走完 → 引擎会清掉快照回空闲。
    final DateTime start = DateTime.now().subtract(const Duration(minutes: 30));
    await box.put(
      TimerSessionStore.sessionKey,
      jsonEncode(
        TimerSession(
          mode: 'countdown',
          totalMs: 25 * 60 * 1000,
          startedAtMs: start.millisecondsSinceEpoch,
          pausedTotalMs: 0,
          endAtMs: start.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
          tag: 'Tag A',
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      ),
    );

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        tagStoreProvider.overrideWithValue(
          TagStore(
            MemoryTagStorage(),
            defaultTags: const <String>['Tag B', 'Tag A'],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(selectedTagProvider), 'Tag B',
        reason: '这一轮已结束,空闲启动应选中历史第一位的 Tag B');
  });
}
