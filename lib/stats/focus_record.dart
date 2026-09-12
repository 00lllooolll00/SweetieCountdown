import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

/// 专注记录所在 Hive box 名（全项目统一）。
const String focusRecordBoxName = 'focus_records';

/// 手写 TypeAdapter 的 typeId，全项目唯一，勿与其他模型冲突。
const int focusRecordTypeId = 7;

/// 未指定标签时使用的默认标签。
const String defaultFocusTag = '专注';

/// 一次专注（番茄钟 / 正计时）记录。
///
/// 时间字段统一为本地时间的 epoch 毫秒（`DateTime.millisecondsSinceEpoch`）。
class FocusRecord {
  FocusRecord({
    required this.uuid,
    required this.startMs,
    required this.endMs,
    required this.seconds,
    this.tag = defaultFocusTag,
  });

  /// 由起止时刻创建记录，[seconds] 自动取整段时长（非法区间记 0 秒）。
  factory FocusRecord.create({
    required DateTime start,
    required DateTime end,
    String tag = defaultFocusTag,
    String? uuid,
  }) {
    final int startMs = start.millisecondsSinceEpoch;
    final int endMs = end.millisecondsSinceEpoch;
    final int seconds = endMs > startMs ? ((endMs - startMs) / 1000).round() : 0;
    return FocusRecord(
      uuid: uuid ?? Uuid().v4(),
      startMs: startMs,
      endMs: endMs,
      seconds: seconds,
      tag: tag,
    );
  }

  /// 由开始时刻 + 时长创建记录。
  factory FocusRecord.fromDuration({
    required DateTime start,
    required Duration duration,
    String tag = defaultFocusTag,
    String? uuid,
  }) =>
      FocusRecord.create(
        start: start,
        end: start.add(duration),
        tag: tag,
        uuid: uuid,
      );

  /// 唯一标识，同时作为 Hive 的存储 key。
  final String uuid;

  /// 开始时刻（epoch 毫秒，本地时区）。
  final int startMs;

  /// 结束时刻（epoch 毫秒，本地时区）。
  final int endMs;

  /// 记录时长（秒），与 [startMs]~[endMs] 一致。
  final int seconds;

  /// 分类标签，如「专注」「阅读」。
  final String tag;

  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs);
  DateTime get end => DateTime.fromMillisecondsSinceEpoch(endMs);
  Duration get duration => Duration(seconds: seconds);

  FocusRecord copyWith({String? tag, int? startMs, int? endMs, int? seconds}) =>
      FocusRecord(
        uuid: uuid,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        seconds: seconds ?? this.seconds,
        tag: tag ?? this.tag,
      );

  @override
  String toString() => 'FocusRecord($uuid, $startMs~$endMs, ${seconds}s, $tag)';
}

/// 手写 TypeAdapter（免 codegen），字段顺序即落盘顺序，勿随意调整。
class FocusRecordAdapter extends TypeAdapter<FocusRecord> {
  @override
  final int typeId = focusRecordTypeId;

  @override
  FocusRecord read(BinaryReader reader) {
    final String uuid = reader.readString();
    final int startMs = reader.readInt();
    final int endMs = reader.readInt();
    final int seconds = reader.readInt();
    final String tag = reader.readString();
    return FocusRecord(
      uuid: uuid,
      startMs: startMs,
      endMs: endMs,
      seconds: seconds,
      tag: tag,
    );
  }

  @override
  void write(BinaryWriter writer, FocusRecord obj) {
    writer.writeString(obj.uuid);
    writer.writeInt(obj.startMs);
    writer.writeInt(obj.endMs);
    writer.writeInt(obj.seconds);
    writer.writeString(obj.tag);
  }
}
