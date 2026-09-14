import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_session_store.dart';

/// 启动恢复：App 被杀后带着快照回来，计时器状态要"原样接上"。
///
/// 覆盖四种恢复分支：暂停中 / 运行未到点 / 运行已过点 / 快照过期。
/// 用真实 Hive 沙箱（引擎启动时就从这个箱读快照）。
void main() {
  late Directory tempDir;
  late Box<dynamic> box;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sweetie_restore_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>('app_settings');
  });

  tearDown(() async {
    // 恢复流程里"补落记录"是 fire-and-forget：给它一点时间落地，
    // 否则 Hive 关箱后它才跑完，会以 unhandled error 形式打断测试。
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> writeSession(TimerSession session) async {
    await box.put(TimerSessionStore.sessionKey, jsonEncode(session.toJson()));
  }

  TimerEngine readEngine() {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(timerEngineProvider);
  }

  final DateTime now = DateTime.now();

  test('暂停中的快照：恢复为暂停态，剩余时间照旧', () async {
    final DateTime start = now.subtract(const Duration(minutes: 5));
    await writeSession(
      TimerSession(
        mode: 'countdown',
        totalMs: 25 * 60 * 1000,
        startedAtMs: start.millisecondsSinceEpoch,
        pausedAtMs: now.millisecondsSinceEpoch,
        pausedTotalMs: 0,
        endAtMs: start.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
        tag: '专注',
        savedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final TimerEngine engine = readEngine();
    expect(engine.isPaused, isTrue, reason: '暂停中杀的，回来应仍是暂停');
    expect(engine.remainingAt(DateTime.now()).inMinutes, 20,
        reason: '已走 5 分钟，剩余 20 分钟');
    expect(engine.statusAt(DateTime.now()), TimerStatus.paused);
  });

  test('运行中未到点：恢复为运行态，剩余 = endAt - now', () async {
    final DateTime start = now.subtract(const Duration(minutes: 4));
    await writeSession(
      TimerSession(
        mode: 'countdown',
        totalMs: 25 * 60 * 1000,
        startedAtMs: start.millisecondsSinceEpoch,
        pausedTotalMs: 0,
        endAtMs: start.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
        tag: '专注',
        savedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final TimerEngine engine = readEngine();
    expect(engine.statusAt(DateTime.now()), TimerStatus.running);
    expect(engine.remainingAt(DateTime.now()).inMinutes, 20,
        reason: '杀掉期间的时间也照常流逝（绝对时间戳的好处）');
  });

  test('运行中已过点：回到空闲（记录由恢复流程补落）', () async {
    final DateTime start = now.subtract(const Duration(minutes: 30));
    await writeSession(
      TimerSession(
        mode: 'countdown',
        totalMs: 25 * 60 * 1000,
        startedAtMs: start.millisecondsSinceEpoch,
        pausedTotalMs: 0,
        endAtMs: start.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
        tag: '专注',
        savedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final TimerEngine engine = readEngine();
    expect(engine.isActive, isFalse, reason: '杀后台期间已走完，回来是干净的空闲态');
    expect(engine.statusAt(DateTime.now()), TimerStatus.idle);
  });

  test('快照超 24 小时：丢弃，不出现"已计时几天"', () async {
    final DateTime old = now.subtract(const Duration(hours: 30));
    await writeSession(
      TimerSession(
        mode: 'stopwatch',
        totalMs: 0,
        startedAtMs: old.millisecondsSinceEpoch,
        pausedTotalMs: 0,
        tag: '专注',
        savedAtMs: old.millisecondsSinceEpoch,
      ),
    );

    final TimerEngine engine = readEngine();
    expect(engine.isActive, isFalse, reason: '过期快照应被丢弃');
  });

  test('没有快照：默认引擎（空闲 + 25 分钟）', () {
    final TimerEngine engine = readEngine();
    expect(engine.isActive, isFalse);
    expect(engine.mode, TimerMode.countdown);
    expect(engine.total, const Duration(minutes: 25));
  });

  test('正计时被杀后回来：已用时间照常累计', () async {
    final DateTime start = now.subtract(const Duration(minutes: 12));
    await writeSession(
      TimerSession(
        mode: 'stopwatch',
        totalMs: 0,
        startedAtMs: start.millisecondsSinceEpoch,
        pausedTotalMs: 0,
        tag: '写论文',
        savedAtMs: now.millisecondsSinceEpoch,
      ),
    );

    final TimerEngine engine = readEngine();
    expect(engine.mode, TimerMode.stopwatch);
    expect(engine.elapsedAt(DateTime.now()).inMinutes, 12);
  });
}
