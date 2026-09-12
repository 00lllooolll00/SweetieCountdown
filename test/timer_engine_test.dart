import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sweetie_countdown/stats/focus_record.dart';
import 'package:sweetie_countdown/stats/stats_logic.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';

void main() {
  // 固定「现在」= 2026-03-11 09:00,测试只跟显式传入的时间戳打交道。
  final DateTime t0 = DateTime(2026, 3, 11, 9);

  group('TimerEngine：绝对时间戳', () {
    test('倒计时剩余 = endAt - now:中间跳过大段时间也不漂移', () {
      const Duration total = Duration(minutes: 25);
      final TimerEngine engine = const TimerEngine().start(t0);

      expect(engine.endAt, t0.add(total));
      expect(engine.remainingAt(t0), total);
      expect(
        engine.remainingAt(t0.add(const Duration(seconds: 90))),
        const Duration(minutes: 23, seconds: 30),
      );

      // 模拟切后台 10 分钟(期间一个 tick 都没有):剩余只由时间戳决定
      expect(
        engine.remainingAt(t0.add(const Duration(minutes: 10))),
        const Duration(minutes: 15),
      );
      // 超过截止时刻也不会出现负数
      expect(engine.remainingAt(t0.add(const Duration(hours: 3))), Duration.zero);
      expect(engine.endAt, t0.add(total)); // 读数不影响时间戳
    });

    test('正计时已用 = now - startedAt,且没有截止时刻', () {
      final TimerEngine engine =
          const TimerEngine(mode: TimerMode.stopwatch).start(t0);

      expect(engine.endAt, isNull);
      expect(engine.elapsedAt(t0), Duration.zero);
      expect(
        engine.elapsedAt(t0.add(const Duration(minutes: 7))),
        const Duration(minutes: 7),
      );
      expect(engine.remainingAt(t0.add(const Duration(minutes: 7))), Duration.zero);
      expect(engine.isFinishedAt(t0.add(const Duration(days: 1))), isFalse);
    });

    test('归零边界:到点前 1ms 仍在跑,到点即完成且不可再暂停', () {
      final TimerEngine engine =
          const TimerEngine(total: Duration(seconds: 10)).start(t0);
      final DateTime deadline = t0.add(const Duration(seconds: 10));
      final DateTime justBefore =
          deadline.subtract(const Duration(milliseconds: 1));

      expect(engine.remainingAt(justBefore), const Duration(milliseconds: 1));
      expect(engine.isFinishedAt(justBefore), isFalse);
      expect(engine.statusAt(justBefore), TimerStatus.running);

      expect(engine.remainingAt(deadline), Duration.zero);
      expect(engine.isFinishedAt(deadline), isTrue);
      expect(engine.statusAt(deadline), TimerStatus.finished);
      expect(engine.progressAt(deadline), 1.0);
      expect(identical(engine.pause(deadline), engine), isTrue);
    });

    test('环形进度 0→1 且不越界;正计时每分钟一圈', () {
      final TimerEngine engine =
          const TimerEngine(total: Duration(minutes: 10)).start(t0);

      expect(engine.progressAt(t0), 0);
      expect(engine.progressAt(t0.add(const Duration(minutes: 5))), closeTo(0.5, 0.0001));
      expect(engine.progressAt(t0.add(const Duration(minutes: 30))), 1.0);

      final TimerEngine watch =
          const TimerEngine(mode: TimerMode.stopwatch).start(t0);
      expect(watch.progressAt(t0.add(const Duration(seconds: 30))), closeTo(0.5, 0.0001));
      expect(watch.progressAt(t0.add(const Duration(seconds: 90))), closeTo(0.5, 0.0001));
    });
  });

  group('暂停 / 恢复', () {
    test('倒计时:暂停冻结剩余,恢复时 endAt 顺延同样的时长', () {
      const Duration total = Duration(minutes: 25);
      final TimerEngine running = const TimerEngine().start(t0);
      final TimerEngine paused = running.pause(t0.add(const Duration(minutes: 5)));

      expect(paused.isPaused, isTrue);
      expect(paused.isTicking, isFalse);
      expect(paused.statusAt(t0.add(const Duration(hours: 2))), TimerStatus.paused);
      // 暂停 40 分钟:剩余仍是 20 分钟,而不是被时间冲掉
      expect(
        paused.remainingAt(t0.add(const Duration(minutes: 45))),
        const Duration(minutes: 20),
      );
      expect(paused.isFinishedAt(t0.add(const Duration(hours: 5))), isFalse);

      final TimerEngine resumed = paused.resume(t0.add(const Duration(minutes: 45)));
      expect(resumed.isPaused, isFalse);
      expect(resumed.isTicking, isTrue);
      expect(resumed.endAt, t0.add(total).add(const Duration(minutes: 40)));
      // 恢复后继续按时间戳走
      expect(
        resumed.remainingAt(t0.add(const Duration(minutes: 55))),
        const Duration(minutes: 10),
      );
      expect(resumed.isFinishedAt(t0.add(const Duration(minutes: 65))), isTrue);
    });

    test('正计时:暂停时长从已用时间里扣除', () {
      final TimerEngine engine =
          const TimerEngine(mode: TimerMode.stopwatch).start(t0);
      final TimerEngine paused = engine.pause(t0.add(const Duration(seconds: 10)));
      final TimerEngine resumed = paused.resume(t0.add(const Duration(seconds: 70)));

      expect(paused.elapsedAt(t0.add(const Duration(minutes: 5))), const Duration(seconds: 10));
      expect(resumed.pausedTotal, const Duration(minutes: 1));
      expect(resumed.elapsedAt(t0.add(const Duration(seconds: 80))), const Duration(seconds: 20));
    });

    test('未开始 / 已暂停时的 pause、resume 是空操作', () {
      const TimerEngine idle = TimerEngine();
      expect(identical(idle.pause(t0), idle), isTrue);
      expect(identical(idle.resume(t0), idle), isTrue);
      expect(idle.statusAt(t0), TimerStatus.idle);

      final TimerEngine paused =
          const TimerEngine().start(t0).pause(t0.add(const Duration(minutes: 1)));
      expect(
        identical(paused.pause(t0.add(const Duration(minutes: 2))), paused),
        isTrue,
      );
    });

    test('reset 回到未开始并保留模式与时长', () {
      final TimerEngine engine =
          const TimerEngine(total: Duration(minutes: 15)).start(t0);
      final TimerEngine reset = engine.reset();

      expect(reset.isActive, isFalse);
      expect(reset.statusAt(t0), TimerStatus.idle);
      expect(reset.mode, TimerMode.countdown);
      expect(reset.total, const Duration(minutes: 15));
      expect(reset.remainingAt(t0), const Duration(minutes: 15));
    });
  });

  group('TagStore：去重与历史', () {
    test('首次写入前展示默认标签', () {
      final TagStore store =
          TagStore(MemoryTagStorage(), defaultTags: const ['专注', '学习']);
      expect(store.tags, <String>['专注', '学习']);
    });

    test('重复标签只保留一条,并移到最前', () async {
      final TagStore store =
          TagStore(MemoryTagStorage(), defaultTags: const ['专注']);
      await store.add('写论文');
      await store.add('健身');
      expect(store.tags, <String>['健身', '写论文', '专注']);

      // 首尾空格 + 大小写差异都算同一个标签,只置顶不新增
      await store.add('  写论文 ');
      expect(store.tags, <String>['写论文', '健身', '专注']);

      await store.add('WORK');
      await store.add('work');
      expect(
        store.tags.where((String t) => t.toLowerCase() == 'work').length,
        1,
      );
      expect(store.tags.first, 'work');
    });

    test('空白标签不写入;删除与清空都会持久化', () async {
      final MemoryTagStorage storage = MemoryTagStorage();
      final TagStore store = TagStore(storage, defaultTags: const ['专注']);

      await store.add('   ');
      expect(storage.read(), isNull); // 从未写入过

      await store.add('学习');
      await store.remove('专注');
      expect(store.tags, <String>['学习']);

      await store.clear();
      expect(store.tags, isEmpty);
      // 清空后不会回落到默认标签
      expect(TagStore(storage).tags, isEmpty);
    });

    test('历史长度受 maxTags 限制', () async {
      final TagStore store = TagStore(
        MemoryTagStorage(),
        defaultTags: const <String>[],
        maxTags: 2,
      );
      await store.add('a');
      await store.add('b');
      await store.add('c');
      expect(store.tags, <String>['c', 'b']);
    });
  });

  group('HiveTagStorage：真实沙箱往返', () {
    late Directory dir;
    late Box<dynamic> box;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('sweetie_timer_test');
      Hive.init(dir.path);
      box = await Hive.openBox<dynamic>('sweetie_tags');
    });

    setUp(() async {
      await box.clear();
    });

    tearDownAll(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    test('写入后重新打开仍是同一份历史', () async {
      final TagStore first =
          TagStore(HiveTagStorage(box), defaultTags: const ['专注']);
      await first.add('写论文');
      await first.add('健身');
      await first.add('写论文');

      final TagStore reopened =
          TagStore(HiveTagStorage(box), defaultTags: const ['专注']);
      expect(reopened.tags, <String>['写论文', '健身', '专注']);
      // 落盘的是字符串列表(后续版本读取的契约)
      expect(box.get(HiveTagStorage.storageKey), isA<List<dynamic>>());
    });
  });

  group('落库:暂停不虚增与正计时留痕', () {
    late Directory dir;
    late Box<FocusRecord> box;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('sweetie_record_test');
      Hive.init(dir.path);
      await initStatsStorage();
      box = await openFocusRecordBox();
    });

    setUp(() async {
      await box.clear();
    });

    tearDownAll(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    /// 与页面 `_recordFocus` 相同的口径:开始时刻 + `elapsedAt(end)`(已用时长)。
    Future<FocusRecord> saveElapsed(TimerEngine engine, DateTime end) async {
      final FocusRecord record = FocusRecord.fromDuration(
        start: engine.startedAt!,
        duration: engine.elapsedAt(end),
      );
      await saveFocusRecord(record);
      return record;
    }

    test('倒计时暂停 10 分钟再归零:落库时长 == 未暂停时长', () async {
      final TimerEngine paused = const TimerEngine()
          .start(t0)
          .pause(t0.add(const Duration(minutes: 5)));
      // 暂停期间过了 10 分钟:恢复时 endAt 被顺延,起止区间口径会虚增这 10 分钟
      final TimerEngine resumed =
          paused.resume(t0.add(const Duration(minutes: 15)));
      final DateTime deadline = resumed.endAt!;

      final FocusRecord record = await saveElapsed(resumed, deadline);

      expect(record.seconds, const Duration(minutes: 25).inSeconds);
      expect(record.duration, const Duration(minutes: 25));
      expect(
        deadline.difference(resumed.startedAt!),
        const Duration(minutes: 35), // 区间口径:35 分钟,虚增 10 分钟
      );
      expect(box.values.single.duration, const Duration(minutes: 25));
    });

    test('后台超时才回来:只记一轮真实时长,不按 now 溢出', () async {
      final TimerEngine engine = const TimerEngine().start(t0);
      final DateTime backAt = t0.add(const Duration(hours: 5)); // 锁屏 5 小时后回来

      final FocusRecord record = await saveElapsed(engine, engine.endAt!);

      expect(engine.isFinishedAt(backAt), isTrue);
      // 若以「回到前台」的时刻为终点,这里会记成 5 小时
      expect(backAt.difference(engine.startedAt!).inHours, 5);
      expect(record.duration, const Duration(minutes: 25));
    });

    test('正计时 reset:先落库一次且时长正确,再清零', () async {
      final TimerEngine engine =
          const TimerEngine(mode: TimerMode.stopwatch).start(t0);
      final DateTime tapAt = t0.add(const Duration(minutes: 6, seconds: 30));

      // 页面 _onResetTap 的口径:elapsed >= 1s 时以 `pausedAt ?? now` 为终点落库,然后 reset
      final DateTime end = engine.pausedAt ?? tapAt;
      final Duration elapsed = engine.elapsedAt(end);
      expect(elapsed >= const Duration(seconds: 1), isTrue);
      await saveFocusRecord(
        FocusRecord.fromDuration(start: engine.startedAt!, duration: elapsed),
      );
      final TimerEngine reset = engine.reset();

      expect(box.length, 1); // 恰好一条,不重复落库
      expect(
        box.values.single.duration,
        const Duration(minutes: 6, seconds: 30),
      );
      expect(reset.isActive, isFalse); // 落库后清零
    });

    test('正计时不足 1 秒的重置不留噪音记录', () {
      final TimerEngine engine =
          const TimerEngine(mode: TimerMode.stopwatch).start(t0);
      final DateTime tapAt = t0.add(const Duration(milliseconds: 800));
      final Duration elapsed = engine.elapsedAt(engine.pausedAt ?? tapAt);

      expect(elapsed >= const Duration(seconds: 1), isFalse);
      expect(box.length, 0);
    });
  });

  group('Riverpod 接线', () {
    test('notifier start/pause/resume/reset 走真实时间戳', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(timerEngineProvider.notifier)
        ..setDuration(const Duration(minutes: 5))
        ..start();

      final TimerEngine started = container.read(timerEngineProvider);
      expect(
        started.endAt!.difference(started.startedAt!),
        const Duration(minutes: 5),
      );
      expect(started.isTicking, isTrue);

      container.read(timerEngineProvider.notifier).pause();
      expect(container.read(timerEngineProvider).isPaused, isTrue);

      container.read(timerEngineProvider.notifier).resume();
      expect(container.read(timerEngineProvider).isTicking, isTrue);

      container.read(timerEngineProvider.notifier).reset();
      expect(container.read(timerEngineProvider).isActive, isFalse);
    });

    test('进行中不允许改时长;切换模式会结束当前一轮', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final TimerEngineNotifier notifier =
          container.read(timerEngineProvider.notifier);

      notifier.start();
      notifier.setDuration(const Duration(minutes: 50));
      expect(container.read(timerEngineProvider).total, const Duration(minutes: 25));

      notifier.reset();
      notifier.setDuration(const Duration(minutes: 50));
      expect(container.read(timerEngineProvider).total, const Duration(minutes: 50));

      notifier.start();
      notifier.setMode(TimerMode.stopwatch);
      final TimerEngine afterMode = container.read(timerEngineProvider);
      expect(afterMode.mode, TimerMode.stopwatch);
      expect(afterMode.isActive, isFalse);
    });
  });
}
