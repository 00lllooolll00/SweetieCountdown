import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/sweetie_theme.dart';
import 'focus_record.dart';
import 'stats_logic.dart';

/// 专注统计页：尺度切换 + 标签占比（饼）+ 时段分布（柱）+ 趋势（折线）。
class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final StatsScale scale = ref.watch(statsScaleProvider);
    final List<FocusRecord> records =
        ref.watch(focusRecordsProvider).valueOrNull ?? const <FocusRecord>[];
    final StatsSnapshot snapshot = ref.watch(statsSnapshotProvider);

    return Scaffold(
      backgroundColor: SweetieColors.background,
      appBar: AppBar(
        backgroundColor: SweetieColors.background,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '专注统计',
          style: TextStyle(
            color: SweetieColors.text,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded, color: SweetieColors.text),
            onPressed: () => ref.invalidate(focusRecordsProvider),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: <Widget>[
            _ScaleChips(current: scale),
            const SizedBox(height: 16),
            if (records.isEmpty)
              const _EmptyCard()
            else ...<Widget>[
              _SummaryCard(snapshot: snapshot),
              const SizedBox(height: 14),
              if (snapshot.isEmpty)
                const _NoDataCard(hint: '这个时间段还没有专注记录哦')
              else ...<Widget>[
                _TagPieCard(
                  tagSeconds: snapshot.tagSeconds,
                  totalSeconds: snapshot.totalSeconds,
                ),
                const SizedBox(height: 14),
                _BucketBarCard(snapshot: snapshot),
                const SizedBox(height: 14),
                _TrendLineCard(snapshot: snapshot),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ScaleChips extends ConsumerWidget {
  const _ScaleChips({required this.current});

  final StatsScale current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final StatsScale scale in StatsScale.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(scale.label),
                selected: scale == current,
                showCheckmark: false,
                onSelected: (_) =>
                    ref.read(statsScaleProvider.notifier).select(scale),
                selectedColor: SweetieColors.pink,
                backgroundColor: SweetieColors.white,
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scale == current ? SweetieColors.white : SweetieColors.text,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(SweetieTheme.radius),
                  side: BorderSide(
                    color: scale == current
                        ? SweetieColors.pink
                        : SweetieColors.pink.withAlpha(90),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SweetCard extends StatelessWidget {
  const _SweetCard({required this.child, this.tint = SweetieColors.pink});

  final Widget child;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: SweetieColors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: tint.withAlpha(40),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text, required this.tint});

  final String text;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: SweetieColors.text,
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.snapshot});

  final StatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return _SweetCard(
      tint: SweetieColors.pink,
      child: Row(
        children: <Widget>[
          Expanded(
            child: _Metric(
              title: '总专注',
              value: formatFocusDuration(snapshot.totalSeconds),
              tint: SweetieColors.pink,
            ),
          ),
          Container(width: 1, height: 44, color: SweetieColors.text.withAlpha(20)),
          Expanded(
            child: _Metric(
              title: '专注次数',
              value: '${snapshot.sessionCount} 次',
              tint: SweetieColors.green,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.title,
    required this.value,
    required this.tint,
  });

  final String title;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: SweetieColors.textLight),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: tint,
          ),
        ),
      ],
    );
  }
}

class _TagPieCard extends StatelessWidget {
  const _TagPieCard({required this.tagSeconds, required this.totalSeconds});

  final Map<String, int> tagSeconds;
  final int totalSeconds;

  @override
  Widget build(BuildContext context) {
    const List<Color> palette = SweetieColors.macarons;
    final List<MapEntry<String, int>> entries = sortedTagEntries(tagSeconds);
    final List<MapEntry<String, int>> shown = entries.take(6).toList();
    if (entries.length > 6) {
      final int rest = entries
          .skip(6)
          .fold(0, (int sum, MapEntry<String, int> e) => sum + e.value);
      shown.add(MapEntry<String, int>('其他', rest));
    }
    return _SweetCard(
      tint: SweetieColors.yellow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionTitle(text: '标签占比', tint: SweetieColors.yellow),
          const SizedBox(height: 12),
          SizedBox(
            height: 190,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                PieChart(
                  PieChartData(
                    sectionsSpace: 3,
                    centerSpaceRadius: 46,
                    sections: <PieChartSectionData>[
                      for (int i = 0; i < shown.length; i++)
                        PieChartSectionData(
                          value: shown[i].value.toDouble(),
                          color: palette[i % palette.length],
                          radius: 58,
                          title: '${(shown[i].value * 100 / totalSeconds).round()}%',
                          showTitle:
                              shown[i].value * 100 / totalSeconds >= 8,
                          titleStyle: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: SweetieColors.white,
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${entries.length}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: SweetieColors.text,
                      ),
                    ),
                    const Text(
                      '个标签',
                      style: TextStyle(fontSize: 11, color: SweetieColors.textLight),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < shown.length; i++)
            _LegendRow(
              color: palette[i % palette.length],
              tag: shown[i].key,
              seconds: shown[i].value,
              totalSeconds: totalSeconds,
            ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.tag,
    required this.seconds,
    required this.totalSeconds,
  });

  final Color color;
  final String tag;
  final int seconds;
  final int totalSeconds;

  @override
  Widget build(BuildContext context) {
    final int percent = totalSeconds <= 0 ? 0 : (seconds * 100 / totalSeconds).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tag,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: SweetieColors.text),
            ),
          ),
          Text(
            formatFocusDuration(seconds),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: SweetieColors.text,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 38,
            child: Text(
              '$percent%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, color: SweetieColors.textLight),
            ),
          ),
        ],
      ),
    );
  }
}

class _BucketBarCard extends StatelessWidget {
  const _BucketBarCard({required this.snapshot});

  final StatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final List<int> values = snapshot.bucketSeconds;
    final int peak = snapshot.peakSeconds;
    final double maxY = peak <= 0 ? 1 : peak / 60 * 1.25;
    final double rodWidth =
        values.length > 20 ? 5 : (values.length > 12 ? 9 : 14);
    return _SweetCard(
      tint: SweetieColors.green,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionTitle(text: '时段分布（分钟）', tint: SweetieColors.green),
          const SizedBox(height: 16),
          SizedBox(
            height: 170,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                alignment: BarChartAlignment.spaceAround,
                barGroups: <BarChartGroupData>[
                  for (int i = 0; i < values.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: <BarChartRodData>[
                        BarChartRodData(
                          toY: values[i] / 60,
                          width: rodWidth,
                          color: values[i] > 0
                              ? SweetieColors.pink
                              : SweetieColors.pink.withAlpha(48),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ],
                    ),
                ],
                titlesData: const FlTitlesData(show: false),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(enabled: false),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _BucketLabels(buckets: snapshot.buckets),
        ],
      ),
    );
  }
}

class _TrendLineCard extends StatelessWidget {
  const _TrendLineCard({required this.snapshot});

  final StatsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final List<int> values = snapshot.bucketSeconds;
    final int peak = snapshot.peakSeconds;
    final double maxY = peak <= 0 ? 1 : peak / 60 * 1.25;
    return _SweetCard(
      tint: SweetieColors.pink,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _SectionTitle(text: '专注趋势（分钟）', tint: SweetieColors.pink),
          const SizedBox(height: 6),
          Text(
            peak <= 0 ? '本时段暂无数据' : '峰值 ${formatFocusDuration(peak)}',
            style: const TextStyle(fontSize: 11, color: SweetieColors.textLight),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 170,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: (values.length - 1).toDouble(),
                minY: 0,
                maxY: maxY,
                lineBarsData: <LineChartBarData>[
                  LineChartBarData(
                    spots: <FlSpot>[
                      for (int i = 0; i < values.length; i++)
                        FlSpot(i.toDouble(), values[i] / 60),
                    ],
                    isCurved: true,
                    curveSmoothness: 0.28,
                    color: SweetieColors.pink,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: SweetieColors.green.withAlpha(56),
                    ),
                  ),
                ],
                titlesData: const FlTitlesData(show: false),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(enabled: false),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _BucketLabels(buckets: snapshot.buckets),
        ],
      ),
    );
  }
}

/// 桶标签行：桶多时按步长抽稀显示，避免文字挤在一起。
class _BucketLabels extends StatelessWidget {
  const _BucketLabels({required this.buckets});

  final List<StatsBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final int step = (buckets.length / 6).ceil();
    return Row(
      children: <Widget>[
        for (int i = 0; i < buckets.length; i++)
          Expanded(
            child: Text(
              i % step == 0 ? buckets[i].label : '',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(fontSize: 9, color: SweetieColors.textLight),
            ),
          ),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    return _SweetCard(
      tint: SweetieColors.pink,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 34),
        child: Column(
          children: <Widget>[
            Icon(
              Icons.local_florist_rounded,
              size: 58,
              color: SweetieColors.pink.withAlpha(150),
            ),
            const SizedBox(height: 14),
            const Text(
              '还没有专注记录',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: SweetieColors.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '完成一个番茄钟，甜甜的专注就会出现在这里~',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: SweetieColors.textLight),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoDataCard extends StatelessWidget {
  const _NoDataCard({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    return _SweetCard(
      tint: SweetieColors.green,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          children: <Widget>[
            Icon(
              Icons.hourglass_empty_rounded,
              size: 42,
              color: SweetieColors.green.withAlpha(200),
            ),
            const SizedBox(height: 12),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: SweetieColors.textLight),
            ),
          ],
        ),
      ),
    );
  }
}
