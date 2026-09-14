import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sweetie_countdown/timer/timer_session_store.dart';

/// 会话快照：JSON 往返、宽松解析、箱不可用时不抛。
///
/// 用真实 Hive 沙箱（临时目录）——要验证的正是箱子的真实行为：
/// JSON 字符串落盘、键删除、箱关闭后的容错。
void main() {
  late Directory tempDir;
  late Box<dynamic> box;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sweetie_session_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>('app_settings');
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TimerSession sample({int? pausedAtMs, int? endAtMs}) => TimerSession(
        mode: 'countdown',
        totalMs: 25 * 60 * 1000,
        startedAtMs: 1757750000000,
        pausedAtMs: pausedAtMs,
        pausedTotalMs: 30000,
        endAtMs: endAtMs,
        tag: '写论文',
        savedAtMs: 1757750100000,
      );

  group('TimerSession 序列化', () {
    test('往返一致', () {
      final TimerSession origin = sample(endAtMs: 1757751500000);
      final TimerSession? restored =
          TimerSession.fromJson(Map<String, dynamic>.from(origin.toJson()));
      expect(restored, isNotNull);
      expect(restored!.mode, 'countdown');
      expect(restored.totalMs, origin.totalMs);
      expect(restored.startedAtMs, origin.startedAtMs);
      expect(restored.pausedTotalMs, origin.pausedTotalMs);
      expect(restored.endAtMs, origin.endAtMs);
      expect(restored.tag, '写论文');
    });

    test('isPaused 语义：有 pausedAtMs 才是暂停中', () {
      expect(sample().isPaused, isFalse);
      expect(sample(pausedAtMs: 1757750050000).isPaused, isTrue);
    });

    test('缺关键字段 → null', () {
      expect(TimerSession.fromJson(<String, dynamic>{}), isNull);
      final Map<String, dynamic> partial = sample().toJson()
        ..remove('startedAtMs');
      expect(TimerSession.fromJson(partial), isNull);
    });

    test('类型错 → null；可选字段类型错则回落默认', () {
      final Map<String, dynamic> wrongType = sample().toJson()
        ..['totalMs'] = '二十五分钟';
      expect(TimerSession.fromJson(wrongType), isNull);

      final Map<String, dynamic> badOptional = sample().toJson()
        ..['tag'] = 42
        ..['endAtMs'] = 'later';
      final TimerSession? restored = TimerSession.fromJson(badOptional);
      expect(restored, isNotNull);
      expect(restored!.tag, '');
      expect(restored.endAtMs, isNull);
    });
  });

  group('TimerSessionStore', () {
    test('save → read 往返（落盘为 JSON 字符串）', () async {
      final TimerSessionStore store = TimerSessionStore(box);
      await store.save(sample(endAtMs: 1757751500000));

      expect(box.get(TimerSessionStore.sessionKey), isA<String>());
      final TimerSession? restored = store.read();
      expect(restored, isNotNull);
      expect(restored!.totalMs, 25 * 60 * 1000);
    });

    test('clear 后 read 为 null', () async {
      final TimerSessionStore store = TimerSessionStore(box);
      await store.save(sample());
      await store.clear();
      expect(store.read(), isNull);
    });

    test('损坏 JSON / 非字符串值 → null（不抛）', () async {
      final TimerSessionStore store = TimerSessionStore(box);
      await box.put(TimerSessionStore.sessionKey, '{不是合法 json');
      expect(store.read(), isNull);

      await box.put(TimerSessionStore.sessionKey, 42);
      expect(store.read(), isNull);
    });

    test('box 为 null：read 返回 null，save/clear 不抛', () async {
      final TimerSessionStore store = TimerSessionStore(null);
      expect(store.read(), isNull);
      await store.save(sample());
      await store.clear();
    });

    test('箱已关闭：read 返回 null、save 静默失败', () async {
      final TimerSessionStore store = TimerSessionStore(box);
      await store.save(sample());
      await box.close();

      expect(store.read(), isNull);
      await store.save(sample()); // 不抛
      await store.clear(); // 不抛
    });

    test('旧快照能被读回（用于恢复判定）', () async {
      final TimerSessionStore store = TimerSessionStore(box);
      final TimerSession paused = sample(pausedAtMs: 1757750050000);
      await box.put(
        TimerSessionStore.sessionKey,
        jsonEncode(paused.toJson()),
      );
      final TimerSession? restored = store.read();
      expect(restored, isNotNull);
      expect(restored!.isPaused, isTrue);
      expect(restored.pausedAtMs, 1757750050000);
    });
  });
}
