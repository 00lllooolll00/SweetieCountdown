import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'focus_record.dart';

// ---------------------------------------------------------------------------
// 尺度
// ---------------------------------------------------------------------------

/// 统计尺度：6 小时 / 12 小时 / 1 天 / 1 周 / 1 月 / 1 年。
///
/// - `last6h` / `last12h`：以当前整点为终点的滚动窗口，按小时分桶；
/// - `day`：今天 00:00~24:00，按小时分桶；
/// - `week`：本周（周一 00:00 起），按天分桶；
/// - `month`：本月（1 号 00:00 起），按天分桶；
/// - `year`：本年（1 月 1 日起），按月分桶。
enum StatsScale {
  last6h('6小时'),
  last12h('12小时'),
  day('1天'),
  week('1周'),
  month('1月'),
  year('1年');

  const StatsScale(this.label);

  /// 尺度切换 chip 上显示的文字。
  final String label;
}

/// 聚合桶，取值区间为半开区间 `[startMs, endMs)`。
class StatsBucket {
  const StatsBucket({
    required this.startMs,
    required this.endMs,
    required this.label,
  });

  final int startMs;
  final int endMs;

  /// 坐标轴上显示的短标签（如 `08`、`周一`、`3`、`12月`）。
  final String label;

  int get spanMs => endMs - startMs;

  @override
  String toString() => 'StatsBucket($label, $startMs~$endMs)';
}

const List<String> _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 生成 [scale] 在当前时刻 [now] 下的全部时间桶（按时间升序，首尾相接）。
///
/// 纯函数：不依赖 `DateTime.now()`，可单测。
List<StatsBucket> buildBuckets(StatsScale scale, DateTime now) {
  switch (scale) {
    case StatsScale.last6h:
    case StatsScale.last12h:
      final int count = scale == StatsScale.last6h ? 6 : 12;
      final DateTime base = _hourFloor(now);
      return [
        for (int i = count - 1; i >= 0; i--)
          _hourBucket(
            DateTime(base.year, base.month, base.day, base.hour - i),
          ),
      ];
    case StatsScale.day:
      final DateTime base = _dayFloor(now);
      return [
        for (int h = 0; h < 24; h++)
          _hourBucket(DateTime(base.year, base.month, base.day, h)),
      ];
    case StatsScale.week:
      final DateTime monday =
          DateTime(now.year, now.month, now.day - (now.weekday - 1));
      return [
        for (int d = 0; d < 7; d++)
          _dayBucket(
            DateTime(monday.year, monday.month, monday.day + d),
            _weekdayLabels[d],
          ),
      ];
    case StatsScale.month:
      final DateTime first = DateTime(now.year, now.month);
      final DateTime next = DateTime(now.year, now.month + 1);
      final List<StatsBucket> buckets = <StatsBucket>[];
      for (DateTime day = first; day.isBefore(next);) {
        final DateTime end = DateTime(day.year, day.month, day.day + 1);
        buckets.add(_bucketOf(day, end, '${day.day}'));
        day = end;
      }
      return buckets;
    case StatsScale.year:
      return [
        for (int m = 1; m <= 12; m++)
          _bucketOf(DateTime(now.year, m), DateTime(now.year, m + 1), '$m月'),
      ];
  }
}

DateTime _hourFloor(DateTime t) => DateTime(t.year, t.month, t.day, t.hour);

DateTime _dayFloor(DateTime t) => DateTime(t.year, t.month, t.day);

StatsBucket _bucketOf(DateTime start, DateTime end, String label) =>
    StatsBucket(
      startMs: start.millisecondsSinceEpoch,
      endMs: end.millisecondsSinceEpoch,
      label: label,
    );

StatsBucket _hourBucket(DateTime start) => _bucketOf(
      start,
      DateTime(start.year, start.month, start.day, start.hour + 1),
      start.hour.toString().padLeft(2, '0'),
    );

StatsBucket _dayBucket(DateTime start, String label) => _bucketOf(
      start,
      DateTime(start.year, start.month, start.day + 1),
      label,
    );

// ---------------------------------------------------------------------------
// 聚合（纯函数）
// ---------------------------------------------------------------------------

/// 单条记录在 `[fromMs, toMs)` 内的有效毫秒数；区间外的部分不计。
///
/// 记录跨越边界时只取重叠部分，这正是「边界切分」的实现基础。
int overlapMillis(FocusRecord record, int fromMs, int toMs) {
  final int start = record.startMs;
  final int end = record.endMs > record.startMs
      ? record.endMs
      : record.startMs + record.seconds * 1000;
  final int lo = start > fromMs ? start : fromMs;
  final int hi = end < toMs ? end : toMs;
  final int ms = hi - lo;
  return ms > 0 ? ms : 0;
}

/// 每个桶内的专注秒数（跨桶的记录按桶边界切分后累加）。
List<int> bucketSecondsOf(List<FocusRecord> records, List<StatsBucket> buckets) {
  if (buckets.isEmpty) return const <int>[];
  final List<int> ms = List<int>.filled(buckets.length, 0);
  final int windowFrom = buckets.first.startMs;
  final int windowTo = buckets.last.endMs;
  for (final FocusRecord record in records) {
    if (overlapMillis(record, windowFrom, windowTo) == 0) continue;
    for (int i = 0; i < buckets.length; i++) {
      final int overlap =
          overlapMillis(record, buckets[i].startMs, buckets[i].endMs);
      if (overlap > 0) ms[i] += overlap;
    }
  }
  return [for (final int value in ms) (value / 1000).round()];
}

/// `[fromMs, toMs)` 内按标签汇总的专注秒数（同样按边界切分）。
Map<String, int> tagSecondsOf(List<FocusRecord> records, int fromMs, int toMs) {
  final Map<String, int> ms = <String, int>{};
  for (final FocusRecord record in records) {
    final int overlap = overlapMillis(record, fromMs, toMs);
    if (overlap > 0) ms[record.tag] = (ms[record.tag] ?? 0) + overlap;
  }
  return <String, int>{
    for (final MapEntry<String, int> entry in ms.entries)
      entry.key: (entry.value / 1000).round(),
  };
}

/// 标签汇总按秒数降序排列（供饼图与图例使用）。
List<MapEntry<String, int>> sortedTagEntries(Map<String, int> tagSeconds) {
  final List<MapEntry<String, int>> entries = tagSeconds.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries;
}

/// 一次聚合的完整结果。
class StatsSnapshot {
  const StatsSnapshot({
    required this.scale,
    required this.buckets,
    required this.bucketSeconds,
    required this.tagSeconds,
    required this.totalSeconds,
    required this.sessionCount,
  });

  final StatsScale scale;
  final List<StatsBucket> buckets;

  /// 与 [buckets] 一一对应的每桶秒数。
  final List<int> bucketSeconds;

  final Map<String, int> tagSeconds;
  final int totalSeconds;

  /// 落在窗口内的记录条数。
  final int sessionCount;

  bool get isEmpty => totalSeconds <= 0;

  /// 单桶峰值秒数（柱状图 Y 轴上限用）。
  int get peakSeconds =>
      bucketSeconds.fold(0, (int max, int value) => value > max ? value : max);
}

/// 按 [scale] 聚合 [records]；[now] 显式传入以保证纯函数可单测。
StatsSnapshot aggregateStats(
  List<FocusRecord> records,
  StatsScale scale,
  DateTime now,
) {
  final List<StatsBucket> buckets = buildBuckets(scale, now);
  final int fromMs = buckets.first.startMs;
  final int toMs = buckets.last.endMs;
  int totalMs = 0;
  int sessions = 0;
  for (final FocusRecord record in records) {
    final int overlap = overlapMillis(record, fromMs, toMs);
    if (overlap > 0) {
      totalMs += overlap;
      sessions++;
    }
  }
  return StatsSnapshot(
    scale: scale,
    buckets: buckets,
    bucketSeconds: bucketSecondsOf(records, buckets),
    tagSeconds: tagSecondsOf(records, fromMs, toMs),
    totalSeconds: (totalMs / 1000).round(),
    sessionCount: sessions,
  );
}

/// 时长文案：`不到1分钟` / `25分钟` / `1小时5分`。
String formatFocusDuration(int seconds) {
  if (seconds <= 0) return '0分钟';
  if (seconds < 60) return '不到1分钟';
  if (seconds < 3600) return '${(seconds / 60).round()}分钟';
  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  return minutes == 0 ? '$hours小时' : '$hours小时$minutes分';
}

// ---------------------------------------------------------------------------
// Hive 存取
// ---------------------------------------------------------------------------

/// 注册 adapter 并确保记录 box 已打开（幂等）。
///
/// Hive 的初始化（`Hive.initFlutter()`）由 main.dart 负责，本模块只读写不 init。
Future<void> initStatsStorage() async {
  if (!Hive.isAdapterRegistered(focusRecordTypeId)) {
    Hive.registerAdapter(FocusRecordAdapter());
  }
  if (!Hive.isBoxOpen(focusRecordBoxName)) {
    await Hive.openBox<FocusRecord>(focusRecordBoxName);
  }
}

/// 取得（必要时先打开）专注记录 box。
Future<Box<FocusRecord>> openFocusRecordBox() async {
  if (Hive.isBoxOpen(focusRecordBoxName)) {
    return Hive.box<FocusRecord>(focusRecordBoxName);
  }
  await initStatsStorage();
  return Hive.box<FocusRecord>(focusRecordBoxName);
}

/// 保存一条专注记录。
Future<void> saveFocusRecord(FocusRecord record) async {
  final Box<FocusRecord> box = await openFocusRecordBox();
  await box.put(record.uuid, record);
}

/// 便捷入口：记录一段已完成的专注（计时结束 / 阅读结束时调用）。
Future<FocusRecord> recordFocusSession({
  required DateTime start,
  required DateTime end,
  String tag = defaultFocusTag,
}) async {
  final FocusRecord record =
      FocusRecord.create(start: start, end: end, tag: tag);
  await saveFocusRecord(record);
  return record;
}

/// 删除一条记录。
Future<void> deleteFocusRecord(String uuid) async {
  final Box<FocusRecord> box = await openFocusRecordBox();
  await box.delete(uuid);
}

/// 全部记录，按开始时间倒序（最新在前）。
List<FocusRecord> sortedRecords(Iterable<FocusRecord> records) =>
    records.toList()..sort((a, b) => b.startMs.compareTo(a.startMs));

// ---------------------------------------------------------------------------
// Riverpod
// ---------------------------------------------------------------------------

/// 全部专注记录；box 发生写入时自动推送新列表。
final StreamProvider<List<FocusRecord>> focusRecordsProvider =
    StreamProvider<List<FocusRecord>>((ref) async* {
  final Box<FocusRecord> box = await openFocusRecordBox();
  List<FocusRecord> read() => sortedRecords(box.values);
  yield read();
  await for (final _ in box.watch()) {
    yield read();
  }
});

/// 当前选中的统计尺度。
class StatsScaleNotifier extends Notifier<StatsScale> {
  @override
  StatsScale build() => StatsScale.day;

  void select(StatsScale value) => state = value;
}

final NotifierProvider<StatsScaleNotifier, StatsScale> statsScaleProvider =
    NotifierProvider<StatsScaleNotifier, StatsScale>(StatsScaleNotifier.new);

/// 当前尺度下的聚合快照。
final Provider<StatsSnapshot> statsSnapshotProvider =
    Provider<StatsSnapshot>((ref) {
  final List<FocusRecord> records =
      ref.watch(focusRecordsProvider).valueOrNull ?? const <FocusRecord>[];
  final StatsScale scale = ref.watch(statsScaleProvider);
  return aggregateStats(records, scale, DateTime.now());
});
