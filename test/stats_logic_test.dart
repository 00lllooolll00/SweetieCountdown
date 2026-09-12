import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:sweetie_countdown/stats/focus_record.dart';
import 'package:sweetie_countdown/stats/stats_logic.dart';

void main() {
  // 固定「现在」= 2026-03-11（周三）13:45，避免依赖真实时钟。
  final DateTime now = DateTime(2026, 3, 11, 13, 45);

  int ms(DateTime t) => t.millisecondsSinceEpoch;

  FocusRecord record(
    DateTime start,
    DateTime end, [
    String tag = defaultFocusTag,
  ]) =>
      FocusRecord.create(start: start, end: end, tag: tag);

  group('buildBuckets：各尺度边界', () {
    test('6小时：6 个整点桶，覆盖 [08:00, 14:00)', () {
      final buckets = buildBuckets(StatsScale.last6h, now);
      expect(buckets.length, 6);
      expect(buckets.first.startMs, ms(DateTime(2026, 3, 11, 8)));
      expect(buckets.last.startMs, ms(DateTime(2026, 3, 11, 13)));
      expect(buckets.last.endMs, ms(DateTime(2026, 3, 11, 14)));
      expect(
        buckets.map((b) => b.label).toList(),
        <String>['08', '09', '10', '11', '12', '13'],
      );
    });

    test('12小时：12 个整点桶，覆盖 [02:00, 14:00)', () {
      final buckets = buildBuckets(StatsScale.last12h, now);
      expect(buckets.length, 12);
      expect(buckets.first.startMs, ms(DateTime(2026, 3, 11, 2)));
      expect(buckets.last.endMs, ms(DateTime(2026, 3, 11, 14)));
    });

    test('1天：今天 00:00~次日 00:00 共 24 桶', () {
      final buckets = buildBuckets(StatsScale.day, now);
      expect(buckets.length, 24);
      expect(buckets.first.startMs, ms(DateTime(2026, 3, 11)));
      expect(buckets.first.label, '00');
      expect(buckets.last.startMs, ms(DateTime(2026, 3, 11, 23)));
      expect(buckets.last.endMs, ms(DateTime(2026, 3, 12)));
    });

    test('1周：本周一 00:00 起共 7 桶', () {
      final buckets = buildBuckets(StatsScale.week, now);
      expect(buckets.length, 7);
      expect(buckets.first.startMs, ms(DateTime(2026, 3, 9)));
      expect(buckets.last.endMs, ms(DateTime(2026, 3, 16)));
      expect(
        buckets.map((b) => b.label).toList(),
        <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'],
      );
    });

    test('1月：本月 1 号起按天分桶（3 月 31 桶）', () {
      final buckets = buildBuckets(StatsScale.month, now);
      expect(buckets.length, 31);
      expect(buckets.first.startMs, ms(DateTime(2026, 3, 1)));
      expect(buckets.first.label, '1');
      expect(buckets.last.startMs, ms(DateTime(2026, 3, 31)));
      expect(buckets.last.endMs, ms(DateTime(2026, 4, 1)));
      expect(buckets.last.label, '31');
    });

    test('1年：1 月~12 月共 12 桶', () {
      final buckets = buildBuckets(StatsScale.year, now);
      expect(buckets.length, 12);
      expect(buckets.first.startMs, ms(DateTime(2026, 1, 1)));
      expect(buckets.last.startMs, ms(DateTime(2026, 12, 1)));
      expect(buckets.last.endMs, ms(DateTime(2027, 1, 1)));
      expect(buckets.last.label, '12月');
    });

    test('所有尺度的桶首尾相接、无空洞', () {
      for (final StatsScale scale in StatsScale.values) {
        final buckets = buildBuckets(scale, now);
        for (int i = 0; i + 1 < buckets.length; i++) {
          expect(
            buckets[i].endMs,
            buckets[i + 1].startMs,
            reason: '${scale.name} 第 $i 桶与下一桶不相接',
          );
        }
      }
    });
  });

  group('边界切分', () {
    test('跨整点的记录按小时拆到两个桶', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 3, 11, 8, 50), DateTime(2026, 3, 11, 9, 10)),
        ],
        StatsScale.last6h,
        now,
      );
      expect(snapshot.totalSeconds, 1200);
      expect(snapshot.bucketSeconds[0], 600); // 08:00~09:00
      expect(snapshot.bucketSeconds[1], 600); // 09:00~10:00
      expect(snapshot.bucketSeconds[2], 0);
      expect(snapshot.sessionCount, 1);
    });

    test('窗口外的部分被裁掉（起点早于窗口 / 终点晚于窗口）', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 3, 11, 7, 50), DateTime(2026, 3, 11, 8, 10)),
          record(DateTime(2026, 3, 11, 13, 55), DateTime(2026, 3, 11, 14, 10)),
        ],
        StatsScale.last6h,
        now,
      );
      expect(snapshot.totalSeconds, 900); // 600 + 300
      expect(snapshot.bucketSeconds.first, 600);
      expect(snapshot.bucketSeconds.last, 300);
      expect(snapshot.sessionCount, 2);
    });

    test('跨天记录在 1天 尺度下只统计今天部分', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 3, 11, 23, 50), DateTime(2026, 3, 12, 0, 10)),
          record(DateTime(2026, 3, 11, 0, 5), DateTime(2026, 3, 11, 0, 35)),
        ],
        StatsScale.day,
        now,
      );
      expect(snapshot.bucketSeconds[23], 600);
      expect(snapshot.bucketSeconds[0], 1800);
      expect(snapshot.totalSeconds, 2400);
    });

    test('跨周记录在 1周 尺度下只统计本周部分', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          // 周日 23:50 → 周一 00:10，只有 600 秒落在本周
          record(DateTime(2026, 3, 8, 23, 50), DateTime(2026, 3, 9, 0, 10)),
        ],
        StatsScale.week,
        now,
      );
      expect(snapshot.bucketSeconds[0], 600);
      expect(snapshot.totalSeconds, 600);
      expect(snapshot.sessionCount, 1);
    });

    test('跨月记录在 1月 尺度下只统计本月部分', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          // 2 月最后一天 23:50 → 3 月 1 日 00:10
          record(DateTime(2026, 2, 28, 23, 50), DateTime(2026, 3, 1, 0, 10)),
        ],
        StatsScale.month,
        now,
      );
      expect(snapshot.bucketSeconds[0], 600);
      expect(snapshot.totalSeconds, 600);
    });

    test('记录结束恰等于桶边界时整段落在左桶', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 3, 11, 8, 10), DateTime(2026, 3, 11, 9, 0)),
        ],
        StatsScale.day,
        now,
      );
      expect(snapshot.bucketSeconds[8], 3000); // [08:00, 09:00)
      expect(snapshot.bucketSeconds[9], 0); // [09:00, 10:00) 不含起点
      expect(snapshot.totalSeconds, 3000);
      expect(snapshot.sessionCount, 1);
    });

    test('12小时：跨整点记录按桶边界一分为二', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 3, 11, 5, 45), DateTime(2026, 3, 11, 6, 15)),
        ],
        StatsScale.last12h,
        now,
      );
      // 窗口 [02:00, 14:00)：下标 3 = [05:00, 06:00)，下标 4 = [06:00, 07:00)
      expect(snapshot.buckets[3].label, '05');
      expect(snapshot.bucketSeconds[3], 900);
      expect(snapshot.bucketSeconds[4], 900);
      expect(snapshot.bucketSeconds[2], 0);
      expect(snapshot.bucketSeconds[5], 0);
      expect(snapshot.totalSeconds, 1800);
    });
  });

  group('FocusRecord.create：非法与零长区间', () {
    test('结束早于开始 → 记 0 秒，且不产生幻影时长', () {
      final FocusRecord created = FocusRecord.create(
        start: DateTime(2026, 3, 11, 10, 0),
        end: DateTime(2026, 3, 11, 9, 0),
      );
      expect(created.startMs, ms(DateTime(2026, 3, 11, 10)));
      expect(created.endMs, ms(DateTime(2026, 3, 11, 9)));
      expect(created.seconds, 0);
      expect(created.duration, Duration.zero);

      final snapshot = aggregateStats(
        <FocusRecord>[created],
        StatsScale.day,
        now,
      );
      expect(snapshot.totalSeconds, 0);
      expect(snapshot.sessionCount, 0);
      expect(snapshot.isEmpty, isTrue);
    });

    test('起止相同 → 记 0 秒', () {
      final DateTime same = DateTime(2026, 3, 11, 10, 30, 15, 250);
      final FocusRecord created = FocusRecord.create(start: same, end: same);
      expect(created.startMs, ms(same));
      expect(created.endMs, ms(same));
      expect(created.seconds, 0);
      expect(created.duration, Duration.zero);
    });
  });

  group('年聚合与标签汇总', () {
    test('按月份聚合，跨年与往年记录被裁剪/排除', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 1, 5, 10, 0), DateTime(2026, 1, 5, 10, 30)),
          record(
            DateTime(2026, 12, 20, 9, 0),
            DateTime(2026, 12, 20, 9, 45),
            '阅读',
          ),
          // 只有 2026-01-01 00:00~00:30 的 1800 秒属于本年
          record(DateTime(2025, 12, 31, 23, 30), DateTime(2026, 1, 1, 0, 30)),
          // 完全在往年，不计入
          record(
            DateTime(2025, 6, 1, 9, 0),
            DateTime(2025, 6, 1, 10, 0),
            '阅读',
          ),
        ],
        StatsScale.year,
        now,
      );
      expect(snapshot.buckets.length, 12);
      expect(snapshot.bucketSeconds[0], 3600); // 1月：1800 + 1800
      expect(snapshot.bucketSeconds[11], 2700); // 12月
      expect(snapshot.totalSeconds, 6300);
      expect(snapshot.sessionCount, 3);
      expect(snapshot.tagSeconds, <String, int>{'专注': 3600, '阅读': 2700});
      expect(snapshot.peakSeconds, 3600);
      expect(snapshot.isEmpty, isFalse);
    });

    test('标签汇总按秒数降序', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(
            DateTime(2026, 3, 11, 9, 0),
            DateTime(2026, 3, 11, 9, 30),
            '阅读',
          ),
          record(DateTime(2026, 3, 11, 10, 0), DateTime(2026, 3, 11, 11, 0)),
        ],
        StatsScale.day,
        now,
      );
      final entries = sortedTagEntries(snapshot.tagSeconds);
      expect(
        entries.map((e) => e.key).toList(),
        <String>['专注', '阅读'],
      );
      expect(
        entries.map((e) => e.value).toList(),
        <int>[3600, 1800],
      );
    });

    test('无记录时快照为空', () {
      final snapshot = aggregateStats(<FocusRecord>[], StatsScale.day, now);
      expect(snapshot.totalSeconds, 0);
      expect(snapshot.sessionCount, 0);
      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.peakSeconds, 0);
      expect(snapshot.bucketSeconds.every((v) => v == 0), isTrue);
    });

    test('窗口与记录无交集时不计入', () {
      final snapshot = aggregateStats(
        <FocusRecord>[
          record(DateTime(2026, 3, 10, 9, 0), DateTime(2026, 3, 10, 10, 0)),
        ],
        StatsScale.last6h,
        now,
      );
      expect(snapshot.isEmpty, isTrue);
      expect(snapshot.sessionCount, 0);
    });
  });

  group('时长文案', () {
    test('formatFocusDuration', () {
      expect(formatFocusDuration(0), '0分钟');
      expect(formatFocusDuration(30), '不到1分钟');
      expect(formatFocusDuration(1500), '25分钟');
      expect(formatFocusDuration(3600), '1小时');
      expect(formatFocusDuration(3900), '1小时5分');
      expect(formatFocusDuration(7200), '2小时');
    });

    test('formatFocusDuration：59/60 分钟与 1 小时边界', () {
      expect(formatFocusDuration(59), '不到1分钟'); // 59 秒
      expect(formatFocusDuration(60), '1分钟'); // 60 秒
      expect(formatFocusDuration(3540), '59分钟'); // 59 分整
      expect(formatFocusDuration(3599), '60分钟'); // 差 1 秒到 1 小时，仍未进位
      expect(formatFocusDuration(3600), '1小时');
      expect(formatFocusDuration(3601), '1小时'); // 秒数进不到分钟
      expect(formatFocusDuration(3660), '1小时1分');
    });
  });

  group('Hive 序列化往返', () {
    late Directory dir;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('sweetie_stats_test');
      Hive.init(dir.path);
      await initStatsStorage();
    });

    tearDownAll(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    test('写入后关闭并重新打开 box，字段完全一致', () async {
      final FocusRecord origin = FocusRecord.create(
        start: DateTime(2026, 3, 11, 9, 0),
        end: DateTime(2026, 3, 11, 9, 25),
        tag: '写代码',
      );
      await saveFocusRecord(origin);

      final Box<FocusRecord> box = await openFocusRecordBox();
      await box.close();

      final Box<FocusRecord> reopened = await openFocusRecordBox();
      final FocusRecord? got = reopened.get(origin.uuid);
      expect(got, isNotNull);
      expect(got!.uuid, origin.uuid);
      expect(got.startMs, origin.startMs);
      expect(got.endMs, origin.endMs);
      expect(got.seconds, 1500);
      expect(got.tag, '写代码');
      expect(got.duration, const Duration(minutes: 25));
    });

    test('recordFocusSession 便捷写入并可再次读回', () async {
      final int before = (await openFocusRecordBox()).length;
      final FocusRecord saved = await recordFocusSession(
        start: DateTime(2026, 3, 11, 14, 0),
        end: DateTime(2026, 3, 11, 14, 25),
        tag: '阅读',
      );
      final Box<FocusRecord> box = await openFocusRecordBox();
      expect(box.length, before + 1);
      expect(box.get(saved.uuid)?.tag, '阅读');
      expect(sortedRecords(box.values).first.startMs, saved.startMs);
    });
  });
}
