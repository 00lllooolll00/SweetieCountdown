import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
}

/// 内存实现(单测 / 预览用)。
class MemoryTagStorage implements TagStorage {
  MemoryTagStorage([List<String>? initial])
      : _tags = initial == null ? null : List<String>.of(initial);

  List<String>? _tags;

  @override
  List<String>? read() => _tags == null ? null : List<String>.of(_tags!);

  @override
  Future<void> write(List<String> tags) async {
    _tags = List<String>.of(tags);
  }
}

/// Hive 实现:整段标签历史存在单个 key 下(最近使用在前)。
class HiveTagStorage implements TagStorage {
  HiveTagStorage(this._box);

  static const String storageKey = 'tag_history';

  final Box<dynamic> _box;

  @override
  List<String>? read() {
    final raw = _box.get(storageKey);
    if (raw is! List) return null;
    return raw.whereType<String>().toList();
  }

  @override
  Future<void> write(List<String> tags) => _box.put(storageKey, tags);
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

  /// 历史长度上限,防止无限增长。
  final int maxTags;

  /// 当前标签列表(不可变副本)。
  List<String> get tags {
    final stored = _storage.read();
    if (stored == null) return List<String>.unmodifiable(defaultTags);
    final seen = <String>{};
    return List<String>.unmodifiable(
      stored.where(
        (tag) => tag.trim().isNotEmpty && seen.add(tag.trim().toLowerCase()),
      ),
    );
  }

  /// 新增 / 置顶:同名(忽略大小写)标签去重后移到最前。
  Future<void> add(String raw) async {
    final name = raw.trim();
    if (name.isEmpty) return;
    final rest = tags.where((tag) => tag.toLowerCase() != name.toLowerCase());
    await _storage.write([name, ...rest].take(maxTags).toList());
  }

  Future<void> remove(String name) async {
    final key = name.trim().toLowerCase();
    await _storage.write(
      tags.where((tag) => tag.toLowerCase() != key).toList(),
    );
  }

  /// 清空后不会回落到默认标签(「已保存为空」与「从未写入」是两种状态)。
  Future<void> clear() => _storage.write(const <String>[]);
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
  @override
  TimerEngine build() => const TimerEngine();

  /// 切换模式会结束当前一轮(回到未开始)。
  void setMode(TimerMode mode) {
    if (state.mode != mode) state = state.withMode(mode);
  }

  /// 设置本轮时长;进行中不允许改。
  void setDuration(Duration duration) {
    if (state.isActive || state.total == duration) return;
    state = state.withDuration(duration);
  }

  void start({Duration? duration}) => state = state.start(
        DateTime.now(),
        duration: duration,
      );

  void pause() => state = state.pause(DateTime.now());

  void resume() => state = state.resume(DateTime.now());

  void reset() => state = state.reset();
}
