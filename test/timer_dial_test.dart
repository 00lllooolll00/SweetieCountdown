import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sweetie_countdown/timer/timer_dial.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';

/// 表盘中央的时钟文本:唯一的 `mm:ss` 形态 Text(状态文案与标签都不含冒号)。
final RegExp _clockPattern = RegExp(r'^\d{2}:\d{2}$');

String _clockText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((Text t) => t.data)
    .whereType<String>()
    .firstWhere(_clockPattern.hasMatch);

Duration _parseClock(String text) {
  final List<int> parts = text.split(':').map(int.parse).toList();
  return Duration(minutes: parts[0], seconds: parts[1]);
}

/// 固定呼吸值 0.5 的帧源:TestVSync 不驱动真实 ticker,只给表盘一个稳定相位。
AnimationController _breath() {
  final AnimationController controller = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(seconds: 2),
    value: 0.5,
  );
  addTearDown(controller.dispose);
  return controller;
}

/// 表盘带常驻动画(呼吸 + 涟漪),只能用固定时长 pump,绝不能 pumpAndSettle。
Future<void> _pumpDial(
  WidgetTester tester, {
  required TimerEngine engine,
  required Listenable frames,
  required Animation<double> breath,
  String? tag,
  VoidCallback? onTapTime,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: TimerDial(
            engine: engine,
            frames: frames,
            breath: breath,
            tag: tag,
            onTapTime: onTapTime ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  group('TimerDial:倒计时', () {
    testWidgets('空闲显示 25:00 与「准备开始」,点按时间文本触发 onTapTime',
        (WidgetTester tester) async {
      final ValueNotifier<int> frames = ValueNotifier<int>(0);
      addTearDown(frames.dispose);
      int taps = 0;

      await _pumpDial(
        tester,
        engine: const TimerEngine(),
        frames: frames,
        breath: _breath(),
        onTapTime: () => taps++,
      );

      expect(find.text('25:00'), findsOneWidget);
      expect(find.text('准备开始'), findsOneWidget);

      await tester.tap(find.text('25:00'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(taps, 1);
    });

    testWidgets('start(now) 后显示剩余时间字符串且状态转为「专注中…」',
        (WidgetTester tester) async {
      final DateTime now = DateTime.now();
      final TimerEngine engine = const TimerEngine().start(now);
      final ValueNotifier<int> frames = ValueNotifier<int>(0);
      addTearDown(frames.dispose);

      await _pumpDial(
        tester,
        engine: engine,
        frames: frames,
        breath: _breath(),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('专注中…'), findsOneWidget);

      // 真实时钟下读数会漂几十毫秒,允许 2 秒以内的显示误差。
      final Duration shown = _parseClock(_clockText(tester));
      expect(
        (engine.remainingAt(now) - shown).abs(),
        lessThan(const Duration(seconds: 2)),
      );
      expect(shown, isNot(Duration.zero));
    });
  });

  group('TimerDial:正计时', () {
    testWidgets('运行中显示已用时间与「计时中…」', (WidgetTester tester) async {
      final DateTime now = DateTime.now();
      final TimerEngine engine = const TimerEngine(mode: TimerMode.stopwatch)
          .start(now.subtract(const Duration(minutes: 1, seconds: 5)));
      final ValueNotifier<int> frames = ValueNotifier<int>(0);
      addTearDown(frames.dispose);

      await _pumpDial(
        tester,
        engine: engine,
        frames: frames,
        breath: _breath(),
      );

      expect(find.text('计时中…'), findsOneWidget);
      final Duration shown = _parseClock(_clockText(tester));
      expect(shown, greaterThanOrEqualTo(const Duration(seconds: 65)));
      expect(shown, lessThan(const Duration(seconds: 70)));
    });

    testWidgets('每帧 Listenable 推进若干次不抛异常', (WidgetTester tester) async {
      final DateTime now = DateTime.now();
      final TimerEngine engine = const TimerEngine(mode: TimerMode.stopwatch)
          .start(now.subtract(const Duration(seconds: 5)));
      final ValueNotifier<int> frames = ValueNotifier<int>(0);
      addTearDown(frames.dispose);

      await _pumpDial(
        tester,
        engine: engine,
        frames: frames,
        breath: _breath(),
        tag: '专注',
      );

      for (int i = 0; i < 5; i++) {
        frames.value++;
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }

      expect(find.text('计时中…'), findsOneWidget);
      expect(find.text('# 专注'), findsOneWidget);
    });
  });

  group('TimerDial:标签胶囊', () {
    testWidgets('传入 tag 渲染「# tag」,未传则不渲染', (WidgetTester tester) async {
      final ValueNotifier<int> frames = ValueNotifier<int>(0);
      addTearDown(frames.dispose);
      final AnimationController breath = _breath();

      await _pumpDial(
        tester,
        engine: const TimerEngine(),
        frames: frames,
        breath: breath,
        tag: '专注',
      );
      expect(find.text('# 专注'), findsOneWidget);

      await _pumpDial(
        tester,
        engine: const TimerEngine(),
        frames: frames,
        breath: breath,
      );
      expect(find.text('# 专注'), findsNothing);
    });
  });
}
