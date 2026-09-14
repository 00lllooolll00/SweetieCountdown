import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

/// 计时会话快照：App 被系统杀掉后，下次启动据此恢复这一轮计时。
///
/// 字段全是原始类型（int / String / null），存成 JSON 字符串落在
/// `app_settings` 箱的 [TimerSessionStore.sessionKey] 键下——这样改字段
/// 也只是读的时候宽松回落，不会像 Hive adapter 那样因顺序错位而炸。
class TimerSession {
  const TimerSession({
    required this.mode,
    required this.totalMs,
    required this.startedAtMs,
    this.pausedAtMs,
    required this.pausedTotalMs,
    this.endAtMs,
    required this.tag,
    required this.savedAtMs,
  });

  /// `'countdown'` 或 `'stopwatch'`。
  final String mode;

  /// 本轮总时长（倒计时目标）。
  final int totalMs;

  /// 开始时刻（epoch ms）。
  final int startedAtMs;

  /// 暂停发生的时刻；null = 运行中。
  final int? pausedAtMs;

  /// 累计暂停时长（恢复时用于顺延 `endAt`）。
  final int pausedTotalMs;

  /// 倒计时截止时刻；正计时为 null。
  final int? endAtMs;

  /// 这一轮绑定的标签。
  final String tag;

  /// 快照写入时刻：恢复时用它判断快照是否已经过期。
  final int savedAtMs;

  bool get isPaused => pausedAtMs != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode,
        'totalMs': totalMs,
        'startedAtMs': startedAtMs,
        'pausedAtMs': pausedAtMs,
        'pausedTotalMs': pausedTotalMs,
        'endAtMs': endAtMs,
        'tag': tag,
        'savedAtMs': savedAtMs,
      };

  /// 宽松解析：任何字段缺失/类型不对都返回 null（调用方据此当作「没有快照」）。
  static TimerSession? fromJson(Map<String, dynamic> json) {
    final Object? mode = json['mode'];
    final Object? totalMs = json['totalMs'];
    final Object? startedAtMs = json['startedAtMs'];
    final Object? pausedTotalMs = json['pausedTotalMs'];
    final Object? savedAtMs = json['savedAtMs'];
    if (mode is! String ||
        totalMs is! int ||
        startedAtMs is! int ||
        pausedTotalMs is! int ||
        savedAtMs is! int) {
      return null;
    }
    final Object? pausedAtMs = json['pausedAtMs'];
    final Object? endAtMs = json['endAtMs'];
    final Object? tag = json['tag'];
    return TimerSession(
      mode: mode,
      totalMs: totalMs,
      startedAtMs: startedAtMs,
      pausedAtMs: pausedAtMs is int ? pausedAtMs : null,
      pausedTotalMs: pausedTotalMs,
      endAtMs: endAtMs is int ? endAtMs : null,
      tag: tag is String ? tag : '',
      savedAtMs: savedAtMs,
    );
  }
}

/// 会话快照的读写：Hive `app_settings` 箱、单个 JSON 字符串键。
///
/// 箱不可用（未初始化/已关闭/泛型不符）时：`read()` 返回 null，
/// `save()`/`clear()` 静默失败——持久化是增强，绝不能拖垮计时本身。
class TimerSessionStore {
  TimerSessionStore(this.box);

  final Box<dynamic>? box;

  static const String sessionKey = 'timer_session';

  TimerSession? read() {
    final Box<dynamic>? target = box;
    if (target == null) return null;
    try {
      final Object? raw = target.get(sessionKey);
      if (raw is! String || raw.trim().isEmpty) return null;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return TimerSession.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(TimerSession session) async {
    final Box<dynamic>? target = box;
    if (target == null) return;
    try {
      await target.put(sessionKey, jsonEncode(session.toJson()));
    } catch (_) {
      // 写失败：这一轮不做恢复，但不影响当前计时。
    }
  }

  Future<void> clear() async {
    final Box<dynamic>? target = box;
    if (target == null) return;
    try {
      await target.delete(sessionKey);
    } catch (_) {
      // 忽略：残留快照会在下次启动按「过期」规则被丢弃。
    }
  }
}
