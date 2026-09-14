import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../settings/translation_settings.dart' show kSettingsBoxName;
import '../stats/focus_record.dart';
import '../stats/stats_logic.dart' show saveFocusRecord;
import 'timer_session_store.dart';

/// 计时模式:倒计时(番茄钟)/ 正计时(秒表)。
enum TimerMode { countdown, stopwatch }

/// 计时状态。
enum TimerStatus { idle, running, paused, finished }

/// 纯 Dart 计时引擎(无任何 Flutter 依赖,可单测)。
///
/// 铁律:剩余 / 已用时长永远由绝对时间戳差值计算
/// (倒计时 `endAt - now`,正计时 `now - startedAt - 累计暂停`),
/// 不存在 `Timer.periodic` 累减 —— 切后台、系统休眠、掉帧都不会漂移。
///
/// 引擎不可变:每次状态迁移返回新实例,可直接 `state = engine.start(now)`。
class TimerEngine {
  const TimerEngine({
    this.mode = TimerMode.countdown,
    this.total = const Duration(minutes: 25),
    this.startedAt,
    this.endAt,
    this.pausedAt,
    this.pausedTotal = Duration.zero,
  });

  /// 本轮总时长(倒计时目标;正计时仅用于展示初始值)。
  final Duration total;

  final TimerMode mode;

  /// 开始时刻(绝对时间戳),null = 未开始。
  final DateTime? startedAt;

  /// 倒计时的绝对截止时刻;正计时恒为 null。
  final DateTime? endAt;

  /// 暂停发生的时刻,null = 未暂停。
  final DateTime? pausedAt;

  /// 累计暂停时长:恢复时把 [endAt] 顺延同样的时长,剩余时间不因暂停缩水。
  final Duration pausedTotal;

  bool get isActive => startedAt != null;

  bool get isPaused => pausedAt != null;

  /// 是否应该走时钟(已开始且未暂停);页面据此启停 Ticker。
  bool get isTicking => isActive && !isPaused;

  TimerStatus statusAt(DateTime now) {
    if (!isActive) return TimerStatus.idle;
    if (isPaused) return TimerStatus.paused;
    if (isFinishedAt(now)) return TimerStatus.finished;
    return TimerStatus.running;
  }

  /// 倒计时剩余:暂停时冻结在暂停那一刻;绝不返回负数。
  Duration remainingAt(DateTime now) {
    if (mode != TimerMode.countdown) return Duration.zero;
    final deadline = endAt;
    if (deadline == null) return total;
    final left = deadline.difference(pausedAt ?? now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 已用时长(两种模式通用),暂停期间冻结。
  Duration elapsedAt(DateTime now) {
    final start = startedAt;
    if (start == null) return Duration.zero;
    final used = (pausedAt ?? now).difference(start) - pausedTotal;
    return used.isNegative ? Duration.zero : used;
  }

  /// 归零判定:倒计时到点(now >= endAt)即完成,边界含等于。
  bool isFinishedAt(DateTime now) =>
      mode == TimerMode.countdown &&
      isActive &&
      remainingAt(now) == Duration.zero;

  /// 环形进度 0..1:倒计时按整轮,正计时每分钟绕一圈。
  double progressAt(DateTime now) {
    if (mode == TimerMode.stopwatch) {
      const lapMs = 60000;
      return (elapsedAt(now).inMilliseconds % lapMs) / lapMs;
    }
    final span = total.inMilliseconds;
    if (span <= 0) return 1;
    final done = span - remainingAt(now).inMilliseconds;
    return (done / span).clamp(0.0, 1.0);
  }

  /// 从 [now] 开始新的一轮(清掉上一轮的暂停记录)。
  TimerEngine start(DateTime now, {TimerMode? mode, Duration? duration}) {
    final nextMode = mode ?? this.mode;
    final nextTotal = duration ?? total;
    return TimerEngine(
      mode: nextMode,
      total: nextTotal,
      startedAt: now,
      endAt: nextMode == TimerMode.countdown ? now.add(nextTotal) : null,
    );
  }

  /// 暂停:记录暂停时刻,剩余时间被冻结(后台多久都不减少)。
  /// 未开始或已完成时是空操作(返回自身)。
  TimerEngine pause(DateTime now) {
    if (!isActive || isPaused || isFinishedAt(now)) return this;
    return TimerEngine(
      mode: mode,
      total: total,
      startedAt: startedAt,
      endAt: endAt,
      pausedAt: now,
      pausedTotal: pausedTotal,
    );
  }

  /// 恢复:把暂停时长记入 [pausedTotal] 并把 [endAt] 顺延同样的时长,
  /// 剩余时间无缝续算。
  TimerEngine resume(DateTime now) {
    final paused = pausedAt;
    if (paused == null) return this;
    final gap = now.isAfter(paused) ? now.difference(paused) : Duration.zero;
    return TimerEngine(
      mode: mode,
      total: total,
      startedAt: startedAt,
      endAt: endAt?.add(gap),
      pausedAt: null,
      pausedTotal: pausedTotal + gap,
    );
  }

  /// 归零重置回未开始状态(保留模式与时长)。
  TimerEngine reset() => TimerEngine(mode: mode, total: total);

  TimerEngine withMode(TimerMode next) =>
      TimerEngine(mode: next, total: total);

  TimerEngine withDuration(Duration next) =>
      TimerEngine(mode: mode, total: next);
}

/// ---------------------------------------------------------------------------
/// 标签历史
/// ---------------------------------------------------------------------------

/// 标签持久化后端:抽出来让单测不依赖 Hive。
abstract class TagStorage {
  /// 返回已保存的标签;从未写入过时返回 null。
  List<String>? read();

  Future<void> write(List<String> tags);

  /// 返回已保存的常驻标签;从未写入过时返回 null。
  List<String>? readPinned();

  Future<void> writePinned(List<String> tags);
}

/// 内存实现(单测 / 预览用)。
class MemoryTagStorage implements TagStorage {
  MemoryTagStorage([List<String>? initial])
      : _tags = initial == null ? null : List<String>.of(initial);

  List<String>? _tags;

  List<String>? _pinned;

  @override
  List<String>? read() => _tags == null ? null : List<String>.of(_tags!);

  @override
  List<String>? readPinned() =>
      _pinned == null ? null : List<String>.of(_pinned!);

  @override
  Future<void> write(List<String> tags) async {
    _tags = List<String>.of(tags);
  }

  @override
  Future<void> writePinned(List<String> tags) async {
    _pinned = List<String>.of(tags);
  }
}

/// Hive 实现:整段标签历史存在单个 key 下(最近使用在前);常驻标签另存一个 key。
class HiveTagStorage implements TagStorage {
  HiveTagStorage(this._box);

  static const String storageKey = 'tag_history';

  /// 常驻标签的存储 key。
  static const String pinnedStorageKey = 'pinned_tags';

  final Box<dynamic> _box;

  @override
  List<String>? read() {
    final raw = _box.get(storageKey);
    if (raw is! List) return null;
    return raw.whereType<String>().toList();
  }

  @override
  List<String>? readPinned() {
    final raw = _box.get(pinnedStorageKey);
    if (raw is! List) return null;
    return raw.whereType<String>().toList();
  }

  @override
  Future<void> write(List<String> tags) => _box.put(storageKey, tags);

  @override
  Future<void> writePinned(List<String> tags) =>
      _box.put(pinnedStorageKey, tags);
}

/// 标签历史:去重(忽略首尾空格与大小写)+ 最近使用在前。
class TagStore {
  TagStore(
    this._storage, {
    this.defaultTags = const ['专注', '学习', '工作', '休息'],
    this.maxTags = 30,
  });

  final TagStorage _storage;

  /// 从未写入过时展示的默认标签。
  final List<String> defaultTags;

  /// 历史长度上限,防止无限增长;常驻项不参与淘汰。
  final int maxTags;

  /// 常驻标签:永远排在 [tags] 最前,保持设置时的顺序,忽略大小写去重。
  List<String> get pinnedTags {
    final stored = _storage.readPinned();
    if (stored == null) return const <String>[];
    final seen = <String>{};
    return List<String>.unmodifiable(
      stored.where(
        (tag) => tag.trim().isNotEmpty && seen.add(tag.trim().toLowerCase()),
      ),
    );
  }

  /// [name] 是否常驻(忽略大小写)。
  bool isPinned(String name) {
    final key = name.trim().toLowerCase();
    return pinnedTags.any((tag) => tag.toLowerCase() == key);
  }

  /// 设置 / 取消常驻;标签还没创建过也可以先常驻。
  Future<void> setPinned(String name, bool pinned) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final key = trimmed.toLowerCase();
    final current = List<String>.of(pinnedTags);
    final exists = current.any((tag) => tag.toLowerCase() == key);
    if (pinned == exists) return;
    if (pinned) {
      current.add(trimmed);
    } else {
      current.removeWhere((tag) => tag.toLowerCase() == key);
    }
    await _storage.writePinned(current);
  }

  /// 当前标签列表(不可变副本):常驻在前,其余按最近使用在前。
  List<String> get tags {
    final seen = <String>{};
    return List<String>.unmodifiable(<String>[
      for (final tag in pinnedTags)
        if (seen.add(tag.toLowerCase())) tag,
      for (final tag in _storedTags)
        if (seen.add(tag.toLowerCase())) tag,
    ]);
  }

  /// 存储顺序的标签(从未写入过时是默认标签),已忽略大小写去重。
  List<String> get _storedTags {
    final stored = _storage.read() ?? defaultTags;
    final seen = <String>{};
    return <String>[
      for (final tag in stored)
        if (tag.trim().isNotEmpty && seen.add(tag.trim().toLowerCase())) tag,
    ];
  }

  /// 新增 / 置顶:同名(忽略大小写)标签去重后移到最前。
  Future<void> add(String raw) async {
    final name = raw.trim();
    if (name.isEmpty) return;
    final key = name.toLowerCase();
    final rest = _storedTags.where((tag) => tag.toLowerCase() != key);
    await _storage.write(_cappedKeepingPinned(<String>[name, ...rest]));
  }

  /// 删除历史的同时清掉常驻状态。
  Future<void> remove(String name) async {
    final key = name.trim().toLowerCase();
    if (isPinned(name)) {
      await _storage.writePinned(
        pinnedTags.where((tag) => tag.toLowerCase() != key).toList(),
      );
    }
    await _storage.write(
      _storedTags.where((tag) => tag.toLowerCase() != key).toList(),
    );
  }

  /// 清空后不会回落到默认标签(「已保存为空」与「从未写入」是两种状态)。
  Future<void> clear() => _storage.write(const <String>[]);

  /// 截断到 [maxTags]:常驻项一定保留(结果可能因此略超上限),其余保持原顺序。
  List<String> _cappedKeepingPinned(List<String> ordered) {
    final pinnedKeys = <String>{for (final tag in pinnedTags) tag.toLowerCase()};
    final kept = <String>[];
    for (final tag in ordered) {
      if (kept.length < maxTags || pinnedKeys.contains(tag.toLowerCase())) {
        kept.add(tag);
      }
    }
    return kept;
  }
}

/// ---------------------------------------------------------------------------
/// Riverpod 接线
/// ---------------------------------------------------------------------------

/// 标签历史所在的 Hive box;main() 启动时 `await openTagBox()` 打开。
const String kTagBoxName = 'sweetie_tags';

Future<Box<dynamic>> openTagBox({String name = kTagBoxName}) async =>
    Hive.isBoxOpen(name)
        ? Hive.box<dynamic>(name)
        : await Hive.openBox<dynamic>(name);

final tagStoreProvider = Provider<TagStore>((ref) {
  if (!Hive.isBoxOpen(kTagBoxName)) {
    throw StateError(
      'Hive box "$kTagBoxName" 尚未打开:请在 main() 里 await openTagBox();',
    );
  }
  return TagStore(HiveTagStorage(Hive.box<dynamic>(kTagBoxName)));
});

final tagHistoryProvider =
    NotifierProvider<TagHistoryNotifier, List<String>>(TagHistoryNotifier.new);

class TagHistoryNotifier extends Notifier<List<String>> {
  TagStore get _store => ref.read(tagStoreProvider);

  @override
  List<String> build() => _store.tags;

  Future<void> add(String name) async {
    await _store.add(name);
    state = _store.tags;
  }

  Future<void> remove(String name) async {
    await _store.remove(name);
    state = _store.tags;
  }

  /// 切换常驻:常驻标签永远排在历史最前。
  Future<void> togglePinned(String tag) async {
    await _store.setPinned(tag, !_store.isPinned(tag));
    state = _store.tags;
  }
}

final selectedTagProvider =
    NotifierProvider<SelectedTagNotifier, String?>(SelectedTagNotifier.new);

/// 当前选中的标签(默认取历史里的第一个),随记录一起被统计页读取。
class SelectedTagNotifier extends Notifier<String?> {
  @override
  String? build() {
    final tags = ref.read(tagHistoryProvider);
    return tags.isEmpty ? null : tags.first;
  }

  void select(String? tag) {
    if (state != tag) state = tag;
  }
}

final timerEngineProvider =
    NotifierProvider<TimerEngineNotifier, TimerEngine>(TimerEngineNotifier.new);

class TimerEngineNotifier extends Notifier<TimerEngine> {
  /// 会话快照存储（与翻译设置共用 `app_settings` 箱）。
  /// Hive 未就绪时返回 null —— 持久化静默跳过，计时功能本身不受影响。
  TimerSessionStore? get _sessionStore {
    if (!Hive.isBoxOpen(kSettingsBoxName)) return null;
    try {
      return TimerSessionStore(Hive.box<dynamic>(kSettingsBoxName));
    } catch (_) {
      return null;
    }
  }

  @override
  TimerEngine build() {
    final TimerSession? session = _sessionStore?.read();
    if (session == null) return const TimerEngine();
    return _restore(session);
  }

  /// 从快照恢复计时器：杀后台/被系统回收后回来，读数依然准确。
  ///
  /// 规则（时间戳全是绝对值，恢复不需要"补计时"）：
  /// - 暂停中 → 原样恢复，用户点「继续」接着走；
  /// - 倒计时运行中且**杀后台期间已经到点** → 补落一条记录后回到空闲；
  /// - 其余运行中 → 按原状态恢复（倒计时剩余 = `endAt - now`，正计时已用 = `now - start - 暂停`）；
  /// - 快照超过 24 小时未更新 → 视为过期丢弃，避免出现「已计时 3 天」这种脏数据。
  TimerEngine _restore(TimerSession session) {
    final DateTime now = DateTime.now();
    final DateTime savedAt =
        DateTime.fromMillisecondsSinceEpoch(session.savedAtMs);
    if (now.difference(savedAt) > const Duration(hours: 24)) {
      unawaited(_clearPersisted());
      return const TimerEngine();
    }

    final TimerMode mode = session.mode == 'stopwatch'
        ? TimerMode.stopwatch
        : TimerMode.countdown;
    final DateTime? endAt = session.endAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(session.endAtMs!);

    // 杀后台期间倒计时已经走完：补一条记录（用户确实专注了那么久），回到空闲。
    if (mode == TimerMode.countdown && endAt != null && !now.isBefore(endAt)) {
      unawaited(_recordFinishedSession(session, endAt));
      unawaited(_clearPersisted());
      return const TimerEngine();
    }

    return TimerEngine(
      mode: mode,
      total: Duration(milliseconds: session.totalMs),
      startedAt: DateTime.fromMillisecondsSinceEpoch(session.startedAtMs),
      endAt: endAt,
      pausedAt: session.pausedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(session.pausedAtMs!),
      pausedTotal: Duration(milliseconds: session.pausedTotalMs),
    );
  }

  /// 补落「杀后台期间自然到点」的专注记录（失败只影响统计，不打断启动）。
  Future<void> _recordFinishedSession(TimerSession session, DateTime endAt) async {
    final DateTime start =
        DateTime.fromMillisecondsSinceEpoch(session.startedAtMs);
    final Duration elapsed =
        endAt.difference(start) - Duration(milliseconds: session.pausedTotalMs);
    if (elapsed < const Duration(seconds: 1)) return;
    try {
      await saveFocusRecord(
        FocusRecord.fromDuration(
          start: start,
          duration: elapsed,
          tag: session.tag.trim().isEmpty ? defaultFocusTag : session.tag,
        ),
      );
    } catch (_) {
      // 落库失败只影响统计。
    }
  }

  /// 把当前状态写成快照；未开始时清掉旧快照（空闲不该留残留）。
  Future<void> _persist() async {
    final TimerSessionStore? store = _sessionStore;
    if (store == null) return;
    final TimerEngine engine = state;
    final DateTime? startedAt = engine.startedAt;
    if (startedAt == null) {
      await store.clear();
      return;
    }
    await store.save(
      TimerSession(
        mode: engine.mode == TimerMode.stopwatch ? 'stopwatch' : 'countdown',
        totalMs: engine.total.inMilliseconds,
        startedAtMs: startedAt.millisecondsSinceEpoch,
        pausedAtMs: engine.pausedAt?.millisecondsSinceEpoch,
        pausedTotalMs: engine.pausedTotal.inMilliseconds,
        endAtMs: engine.endAt?.millisecondsSinceEpoch,
        tag: ref.read(selectedTagProvider) ?? defaultFocusTag,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _clearPersisted() async => _sessionStore?.clear();

  /// 切换模式会结束当前一轮(回到未开始)。
  void setMode(TimerMode mode) {
    if (state.mode == mode) return;
    state = state.withMode(mode);
    unawaited(_persist());
  }

  /// 设置本轮时长;进行中不允许改。
  void setDuration(Duration duration) {
    if (state.isActive || state.total == duration) return;
    state = state.withDuration(duration);
    unawaited(_persist());
  }

  void start({Duration? duration}) {
    state = state.start(DateTime.now(), duration: duration);
    unawaited(_persist());
  }

  void pause() {
    state = state.pause(DateTime.now());
    unawaited(_persist());
  }

  void resume() {
    state = state.resume(DateTime.now());
    unawaited(_persist());
  }

  void reset() {
    state = state.reset();
    unawaited(_clearPersisted());
  }
}
