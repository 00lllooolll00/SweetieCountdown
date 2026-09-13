import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stats/focus_record.dart';
import '../stats/stats_logic.dart';
import '../theme/sweetie_theme.dart';
import 'timer_engine.dart';

/// 计时主页:环形计时器 + 标签胶囊 + 开始/暂停/重置。
///
/// 页面不做任何计时累减:运行期间由 [Ticker] 每帧读取「时间戳差值」重绘,
/// 暂停 / 结束后立刻停帧,空闲时不占 CPU。
class TimerPage extends ConsumerStatefulWidget {
  const TimerPage({super.key});

  @override
  ConsumerState<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends ConsumerState<TimerPage>
    with TickerProviderStateMixin {
  late final Ticker _ticker;

  /// 呼吸滚动：驱动整页氛围光缓慢漂移与脉动（与计时状态无关，常驻轻呼吸）。
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 7200),
  )..repeat(reverse: true);

  /// 帧计数:驱动环形进度与时间文本重绘。
  final ValueNotifier<int> _frames = ValueNotifier<int>(0);

  Timer? _celebrateTimer;
  bool _celebrating = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onFrame);
    _syncTicker();
  }

  @override
  void dispose() {
    _celebrateTimer?.cancel();
    _frames.dispose();
    _breath.dispose();
    // Ticker.dispose() 断言「不能在活动状态被销毁」,先停再销毁。
    _ticker
      ..stop()
      ..dispose();
    super.dispose();
  }

  /// 只在「已开始且未暂停」时走帧;暂停/归零立即停。
  void _syncTicker() {
    final ticking = ref.read(timerEngineProvider).isTicking;
    if (ticking && !_ticker.isActive) {
      _ticker.start();
    } else if (!ticking && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onFrame(Duration _) {
    _frames.value++;
    if (ref.read(timerEngineProvider).isFinishedAt(DateTime.now())) {
      _ticker.stop();
      _celebrate();
    }
  }

  /// 归零:糖果动画 + 震动 + 落一条专注记录。
  void _celebrate() {
    if (_celebrating) return;
    setState(() => _celebrating = true);
    HapticFeedback.vibrate();
    unawaited(_recordFocus());
    _celebrateTimer?.cancel();
    _celebrateTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _celebrating = false);
    });
  }

  /// 把刚完成的一轮交给统计模块(写失败不影响动画与界面)。
  ///
  /// 时长取「已用时间」`elapsedAt(endAt)` 而不是 `startedAt→endAt` 区间:
  /// 暂停恢复会把 [TimerEngine.endAt] 顺延,区间口径会虚增;
  /// 后台超时(回到前台时 now 远超截止时刻)也只会记一轮的真实时长。
  Future<void> _recordFocus() async {
    final engine = ref.read(timerEngineProvider);
    final start = engine.startedAt;
    if (start == null) return;
    final tag = ref.read(selectedTagProvider) ?? defaultFocusTag;
    try {
      await saveFocusRecord(
        FocusRecord.fromDuration(
          start: start,
          duration: engine.elapsedAt(engine.endAt ?? DateTime.now()),
          tag: tag,
        ),
      );
    } catch (_) {
      // 落库失败只影响统计,不打断庆祝
    }
  }

  void _onPrimaryTap() {
    final notifier = ref.read(timerEngineProvider.notifier);
    switch (ref.read(timerEngineProvider).statusAt(DateTime.now())) {
      case TimerStatus.idle:
      case TimerStatus.finished:
        notifier.start();
      case TimerStatus.running:
        notifier.pause();
      case TimerStatus.paused:
        notifier.resume();
    }
    if (_celebrating) setState(() => _celebrating = false);
    _syncTicker();
  }

  /// 结束/中断前留痕:已用 ≥1s 才落库(误触不留噪音记录),再清零。
  /// 终点取 `pausedAt ?? now`:暂停中结束不会把暂停时长算进去。
  Future<void> _recordElapsed(TimerEngine engine) async {
    final start = engine.startedAt;
    if (start == null) return;
    final end = engine.pausedAt ?? DateTime.now();
    final elapsed = engine.elapsedAt(end);
    if (elapsed < const Duration(seconds: 1)) return;
    final tag = ref.read(selectedTagProvider) ?? defaultFocusTag;
    try {
      await saveFocusRecord(
        FocusRecord.fromDuration(start: start, duration: elapsed, tag: tag),
      );
    } catch (_) {
      // 落库失败只影响统计,不打断重置
    }
  }

  /// 结束当前一轮:倒计时「提前结束」、正计时「结束」,都会把已用时长记进统计。
  void _onEndTap() {
    final engine = ref.read(timerEngineProvider);
    if (engine.isActive) {
      unawaited(_recordElapsed(engine));
    }
    ref.read(timerEngineProvider.notifier).reset();
    if (_celebrating) setState(() => _celebrating = false);
    _syncTicker();
  }

  void _onResetTap() {
    final engine = ref.read(timerEngineProvider);
    if (engine.mode == TimerMode.stopwatch && engine.isActive) {
      unawaited(_recordElapsed(engine));
    }
    ref.read(timerEngineProvider.notifier).reset();
    if (_celebrating) setState(() => _celebrating = false);
    _syncTicker();
  }

  /// 点表盘时间:倒计时未开始 / 刚结束时选新时长;进行中只提示,不改时长。
  Future<void> _pickDuration() async {
    final engine = ref.read(timerEngineProvider);
    if (engine.mode != TimerMode.countdown) return;
    final status = engine.statusAt(DateTime.now());
    if (status == TimerStatus.running || status == TimerStatus.paused) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('计时进行中，先重置再调时长吧～'),
          duration: Duration(milliseconds: 1400),
        ),
      );
      return;
    }

    final picked = await showModalBottomSheet<Duration>(
      context: context,
      // 内容比 9/16 屏高,放开高度上限,避免小屏溢出。
      isScrollControlled: true,
      builder: (_) => _DurationSheet(initial: engine.total),
    );
    if (picked == null || !mounted) return;

    final notifier = ref.read(timerEngineProvider.notifier);
    // 结束后的引擎仍带 startedAt,setDuration 会按「进行中」拦下,先归零再改。
    if (ref.read(timerEngineProvider).isActive) {
      notifier.reset();
      if (_celebrating) setState(() => _celebrating = false);
    }
    notifier.setDuration(picked);
  }

  Future<void> _promptCustomTag() async {
    final input = await showDialog<String>(
      context: context,
      builder: (_) => const _TagInputDialog(),
    );
    final tag = input?.trim() ?? '';
    if (tag.isEmpty || !mounted) return;
    await ref.read(tagHistoryProvider.notifier).add(tag);
    ref.read(selectedTagProvider.notifier).select(tag);
  }

  Future<void> _confirmRemoveTag(String tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: SweetieColors.white,
        shape: const RoundedRectangleBorder(borderRadius: SweetieTheme.cardRadius),
        title: Text('删除标签「$tag」?', style: const TextStyle(fontSize: 18)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: SweetieColors.pink),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await ref.read(tagHistoryProvider.notifier).remove(tag);
    if (ref.read(selectedTagProvider) != tag) return;
    final rest = ref.read(tagHistoryProvider);
    ref.read(selectedTagProvider.notifier).select(rest.isEmpty ? null : rest.first);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TimerEngine>(timerEngineProvider, (_, __) => _syncTicker());

    final engine = ref.watch(timerEngineProvider);
    final tags = ref.watch(tagHistoryProvider);
    final selectedTag = ref.watch(selectedTagProvider);
    final status = engine.statusAt(DateTime.now());
    // 计时进行中/暂停中：左侧按钮变为「提前结束」（倒计时）/「结束」（正计时）。
    final bool canEnd =
        status == TimerStatus.running || status == TimerStatus.paused;
    // 整页氛围色：与表盘同源，让顶部模式切换/标签/表盘/按钮共享一个背景光。
    final accent = switch (status) {
      TimerStatus.finished => SweetieColors.green,
      TimerStatus.paused => SweetieColors.yellow,
      _ => SweetieColors.pink,
    };

    return Scaffold(
      backgroundColor: SweetieColors.background,
      body: TweenAnimationBuilder<Color?>(
        // 状态色切换时平滑过渡粉/黄/绿。
        tween: ColorTween(end: accent),
        duration: const Duration(milliseconds: 560),
        curve: Curves.easeOut,
        builder: (context, tintColor, _) {
          final Color tint = tintColor ?? accent;
          return AnimatedBuilder(
            animation: _breath,
            builder: (context, __) {
              // 背景 = 纯色底 + 分散粉色光斑,各自错相呼吸(缩放/漂移/明暗)。
              // 不用整屏径向/线性渐变:那种"大渐变收尾"会在屏内留下一条弧状分界线。
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  const ColoredBox(color: SweetieColors.background),
                  for (final _Blob b in _kBlobs)
                    _BreathingBlob(
                      blob: b,
                      tint: tint,
                      breathValue: _breath.value,
                    ),
                  SafeArea(
                child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 12),
                _ModeToggle(
                  mode: engine.mode,
                  enabled:
                      status == TimerStatus.idle || status == TimerStatus.finished,
                  onChanged: (mode) =>
                      ref.read(timerEngineProvider.notifier).setMode(mode),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  // 高度 = 胶囊 44 + 上下各 20 的光晕空间:ListView 默认硬裁切,
                  // 不留空间的话选中胶囊的柔光只剩左右两截,上下会被切掉。
                  height: 84,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 20,
                    ),
                    itemCount: tags.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      if (index == tags.length) {
                        return _AddTagChip(onTap: _promptCustomTag);
                      }
                      final tag = tags[index];
                      return _TagChip(
                        label: tag,
                        active: tag == selectedTag,
                        onTap: () =>
                            ref.read(selectedTagProvider.notifier).select(tag),
                        onLongPress: () => _confirmRemoveTag(tag),
                      );
                    },
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _Dial(
                          engine: engine,
                          frames: _frames,
                          breath: _breath,
                          tag: selectedTag,
                          onTapTime: _pickDuration,
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _RoundButton(
                              icon: canEnd
                                  ? Icons.stop_rounded
                                  : Icons.refresh_rounded,
                              label: canEnd
                                  ? (engine.mode == TimerMode.countdown
                                      ? '提前结束'
                                      : '结束')
                                  : '重置',
                              onTap: canEnd ? _onEndTap : _onResetTap,
                            ),
                            const SizedBox(width: 28),
                            _RoundButton(
                              primary: true,
                              icon: switch (status) {
                                TimerStatus.idle => Icons.play_arrow_rounded,
                                TimerStatus.running => Icons.pause_rounded,
                                TimerStatus.paused => Icons.play_arrow_rounded,
                                TimerStatus.finished => Icons.replay_rounded,
                              },
                              label: switch (status) {
                                TimerStatus.idle => '开始',
                                TimerStatus.running => '暂停',
                                TimerStatus.paused => '继续',
                                TimerStatus.finished => '再来一次',
                              },
                              onTap: _onPrimaryTap,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
            if (_celebrating) const _CandyBurst(),
          ],
                ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 环形计时器
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 背景呼吸色块
// ---------------------------------------------------------------------------

/// 背景光斑:位置/尺寸/呼吸相位/色相偏移(0=跟随状态色, 1=焦糖黄, 2=薄荷绿)。
class _Blob {
  const _Blob(this.align, this.size, this.phase, this.hueShift);

  final Alignment align;
  final double size;
  final double phase;
  final int hueShift;

  Color color(Color tint) => switch (hueShift) {
        1 => SweetieColors.yellow,
        2 => SweetieColors.green,
        _ => tint,
      };
}

/// 分散在整页的色块:各自错开相位,缓慢缩放/漂移/明暗变化 = 分散呼吸。
const List<_Blob> _kBlobs = <_Blob>[
  _Blob(Alignment(-0.88, -0.82), 340, 0.00, 0),
  _Blob(Alignment(0.92, -0.58), 300, 0.33, 1),
  _Blob(Alignment(-0.95, 0.08), 280, 0.66, 2),
  _Blob(Alignment(0.82, 0.28), 360, 0.15, 0),
  _Blob(Alignment(-0.52, 0.86), 320, 0.50, 1),
  _Blob(Alignment(0.62, 0.96), 260, 0.83, 0),
];

class _BreathingBlob extends StatelessWidget {
  const _BreathingBlob({
    required this.blob,
    required this.tint,
    required this.breathValue,
  });

  final _Blob blob;
  final Color tint;
  final double breathValue;

  @override
  Widget build(BuildContext context) {
    // 连续三角波(0→1→0→1...):递增到最大再递减到最小,循环往复;
    // 直接用 (v+phase)%1 会在环绕处跳变,呼吸就不平滑了。
    final double p = (breathValue + blob.phase) % 2.0;
    final double tri = p <= 1.0 ? p : 2.0 - p;
    final double t = Curves.easeInOutSine.transform(tri);
    final Color c = blob.color(tint);
    final double alpha = 0.05 + 0.09 * t;
    return Align(
      alignment: blob.align,
      child: Transform.translate(
        offset: Offset(0, -14 + 28 * t),
        child: Transform.scale(
          scale: 0.86 + 0.30 * t,
          child: Container(
            width: blob.size,
            height: blob.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  c.withValues(alpha: alpha),
                  c.withValues(alpha: alpha * 0.55),
                  c.withValues(alpha: 0.0),
                ],
                stops: const <double>[0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const double _dialSize = 264;

String _formatClock(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds' : '$minutes:$seconds';
}

String _statusLabel(TimerStatus status, TimerMode mode) {
  switch (status) {
    case TimerStatus.idle:
      return mode == TimerMode.countdown ? '准备开始' : '随时开始';
    case TimerStatus.running:
      return mode == TimerMode.countdown ? '专注中…' : '计时中…';
    case TimerStatus.paused:
      return '已暂停';
    case TimerStatus.finished:
      return '完成啦';
  }
}

class _Dial extends StatelessWidget {
  const _Dial({
    required this.engine,
    required this.frames,
    required this.breath,
    required this.tag,
    required this.onTapTime,
  });

  final TimerEngine engine;
  final Listenable frames;

  /// 与整页氛围同频的呼吸进度(0..1),驱动光晕脉动。
  final Animation<double> breath;
  final String? tag;

  /// 点按中央时间文本:倒计时未开始 / 刚结束时弹时长选择。
  final VoidCallback onTapTime;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[frames, breath]),
      builder: (context, _) {
        final now = DateTime.now();
        final status = engine.statusAt(now);
        final shown = engine.mode == TimerMode.countdown
            ? engine.remainingAt(now)
            : engine.elapsedAt(now);
        final accent = switch (status) {
          TimerStatus.finished => SweetieColors.green,
          TimerStatus.paused => SweetieColors.yellow,
          _ => SweetieColors.pink,
        };

        return SizedBox.square(
          dimension: _dialSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 同色光晕：与整页氛围同频呼吸，柔和过渡并统一背景。
              Container(
                width: 292,
                height: 292,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(
                    alpha: 0.05 +
                        0.05 * Curves.easeInOutSine.transform(breath.value),
                  ),
                ),
              ),
              Container(
                width: 226,
                height: 226,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 糖感:中心纯白,向边缘晕一层极淡状态色,比死白更"软"。
                  gradient: RadialGradient(
                    colors: <Color>[
                      SweetieColors.white,
                      Color.alphaBlend(
                        accent.withValues(alpha: 0.06),
                        SweetieColors.white,
                      ),
                    ],
                    stops: const <double>[0.55, 1.0],
                  ),
                  boxShadow: SweetieTheme.cardShadow(accent),
                ),
              ),
              CustomPaint(
                size: const Size.square(_dialSize),
                painter: _RingPainter(
                  progress: engine.mode == TimerMode.countdown
                      // 倒计时:环从全满向空递减(剩余比例)。
                      // 引擎给的是"已用比例"(递增),此处取反;正计时保持每分钟一圈递增。
                      ? 1.0 - engine.progressAt(now)
                      : engine.progressAt(now),
                  color: accent,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTapTime,
                    child: Semantics(
                      button: true,
                      child: Text(
                        _formatClock(shown),
                        style: const TextStyle(
                          fontSize: 46,
                          fontWeight: FontWeight.w800,
                          color: SweetieColors.text,
                          letterSpacing: 1.5,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _statusLabel(status, engine.mode),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                  if (tag != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: SweetieColors.pink.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
                      ),
                      child: Text(
                        '# $tag',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: SweetieColors.pink,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.07;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.20)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.14),
    );

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * clamped,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: <Color>[color, SweetieColors.yellow],
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(rect),
    );

    // 弧头糖果珠:跟着进度走,白边 + 焦糖心,给表盘一个"可读的端点"。
    final double head = -math.pi / 2 + math.pi * 2 * clamped;
    final Offset tip = Offset(
      center.dx + math.cos(head) * radius,
      center.dy + math.sin(head) * radius,
    );
    canvas.drawCircle(tip, stroke * 0.62, Paint()..color = SweetieColors.white);
    canvas.drawCircle(
      tip,
      stroke * 0.40,
      Paint()..color = SweetieColors.yellow,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// 时长选择
// ---------------------------------------------------------------------------

/// 倒计时时长选择:预设胶囊 + 滑杆(5~90 分钟,步进 5),确认后返回所选时长。
class _DurationSheet extends StatefulWidget {
  const _DurationSheet({required this.initial});

  final Duration initial;

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  static const List<int> _presets = <int>[5, 10, 15, 25, 30, 45, 60];
  static const int _minMinutes = 5;
  static const int _maxMinutes = 90;
  static const int _stepMinutes = 5;

  /// 当前选择(分钟),始终落在 5 分钟步进上。
  late double _minutes = _snap(widget.initial);

  /// 初始时长吸附到步进并夹进区间,避免滑杆停在非法刻度上。
  static double _snap(Duration duration) {
    final rounded = (duration.inMinutes / _stepMinutes).round() * _stepMinutes;
    return rounded.clamp(_minMinutes, _maxMinutes).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _minutes.round();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '倒计时时长',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              '$minutes 分钟',
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                color: SweetieColors.pink,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final preset in _presets)
                  _PresetChip(
                    minutes: preset,
                    active: minutes == preset,
                    onTap: () => setState(() => _minutes = preset.toDouble()),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Slider(
              value: _minutes,
              min: _minMinutes.toDouble(),
              max: _maxMinutes.toDouble(),
              divisions: (_maxMinutes - _minMinutes) ~/ _stepMinutes,
              label: '$minutes 分钟',
              onChanged: (value) => setState(() => _minutes = value),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('5 分钟', style: TextStyle(fontSize: 12, color: SweetieColors.textLight)),
                  Text('90 分钟', style: TextStyle(fontSize: 12, color: SweetieColors.textLight)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: SweetieColors.pink,
                  foregroundColor: SweetieColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  shape: const RoundedRectangleBorder(
                    borderRadius: SweetieTheme.cardRadius,
                  ),
                ),
                onPressed: () =>
                    Navigator.of(context).pop(Duration(minutes: minutes)),
                child: const Text('确认'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.minutes,
    required this.active,
    required this.onTap,
  });

  final int minutes;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: SweetieTheme.animationDuration,
        curve: SweetieTheme.animationCurve,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? SweetieColors.pink : SweetieColors.soft(SweetieColors.pink),
          borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
          boxShadow: SweetieTheme.pillGlow(active: active),
        ),
        child: Text(
          '$minutes 分钟',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: active ? SweetieColors.white : SweetieColors.text,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 标签条
// ---------------------------------------------------------------------------

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: SweetieTheme.animationDuration,
        curve: SweetieTheme.animationCurve,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: active ? SweetieColors.pink : SweetieColors.white,
          borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
          border: Border.all(
            color: active
                ? SweetieColors.pink
                : SweetieColors.pink.withValues(alpha: 0.16),
            width: 1.2,
          ),
          // 选中态:四周均匀扩散的柔粉光(offset 归零 → 不偏向底部,不会连成横线)。
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: SweetieColors.pink.withValues(alpha: active ? 0.30 : 0.0),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Text(
          '# $label',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: active ? SweetieColors.white : SweetieColors.text,
          ),
        ),
      ),
    );
  }
}

class _AddTagChip extends StatelessWidget {
  const _AddTagChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: SweetieColors.white,
          borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
          border: Border.all(
            color: SweetieColors.pink.withValues(alpha: 0.20),
            width: 1.2,
          ),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 18, color: SweetieColors.pink),
            SizedBox(width: 4),
            Text(
              '自定义',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: SweetieColors.pink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义标签弹窗:自动聚焦输入框,软键盘直接弹出,回车即提交。
class _TagInputDialog extends StatefulWidget {
  const _TagInputDialog();

  @override
  State<_TagInputDialog> createState() => _TagInputDialogState();
}

class _TagInputDialogState extends State<_TagInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: SweetieColors.white,
      shape: const RoundedRectangleBorder(borderRadius: SweetieTheme.cardRadius),
      title: const Text('自定义标签', style: TextStyle(fontSize: 18)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 12,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: '比如:写论文',
          counterText: '',
          filled: true,
          fillColor: SweetieColors.background,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(SweetieTheme.radius),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '取消',
            style: TextStyle(color: SweetieColors.textLight),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: SweetieColors.pink),
          onPressed: _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 模式切换与按钮
// ---------------------------------------------------------------------------

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final TimerMode mode;
  final bool enabled;
  final ValueChanged<TimerMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: SweetieColors.white,
            borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
            border: Border.all(
              color: SweetieColors.pink.withValues(alpha: 0.16),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _segment('倒计时', TimerMode.countdown),
              _segment('正计时', TimerMode.stopwatch),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(String label, TimerMode value) {
    final active = mode == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: SweetieTheme.animationDuration,
        curve: SweetieTheme.animationCurve,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: active ? SweetieColors.pink : Colors.transparent,
          borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: active ? SweetieColors.white : SweetieColors.textLight,
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatefulWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.primary ? 92.0 : 64.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          child: AnimatedScale(
            scale: _pressed ? 0.92 : 1,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.primary ? SweetieColors.pink : SweetieColors.white,
                boxShadow: widget.primary
                    ? SweetieTheme.buttonShadow(SweetieColors.pink)
                    : SweetieTheme.cardShadow(SweetieColors.pink),
              ),
              child: Icon(
                widget.icon,
                size: widget.primary ? 42 : 28,
                color: widget.primary ? SweetieColors.white : SweetieColors.pink,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: SweetieColors.text,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 归零糖果动画
// ---------------------------------------------------------------------------

class _CandyBurst extends StatelessWidget {
  const _CandyBurst();

  static const List<String> _candies = [
    '🍬',
    '🍭',
    '🧁',
    '🍩',
    '🍪',
    '🍫',
    '🍬',
    '🍭',
  ];

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < _candies.length; i++) _candy(i),
            Text(
              '完成啦 🎉',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: SweetieColors.pink,
              ),
            )
                .animate()
                .fadeIn(duration: 200.milliseconds, curve: Curves.easeOut)
                .scaleXY(
                  begin: 0.4,
                  end: 1,
                  duration: 520.milliseconds,
                  curve: Curves.easeOutBack,
                ),
          ],
        ),
      ),
    );
  }

  /// flutter_animate 的 effect 默认并行,因此用 delay 把「弹出→飘走→淡出」排开。
  Widget _candy(int index) {
    final angle = index * (math.pi * 2 / _candies.length);
    return Transform.translate(
      offset: Offset(math.cos(angle) * 96, math.sin(angle) * 96),
      child: Text(_candies[index], style: const TextStyle(fontSize: 32)),
    )
        .animate(delay: (index * 60).milliseconds)
        .fadeIn(duration: 240.milliseconds, curve: Curves.easeOut)
        .scaleXY(
          begin: 0.2,
          end: 1,
          duration: 520.milliseconds,
          curve: Curves.easeOutBack,
        )
        .moveY(
          begin: 0,
          end: -20,
          delay: 200.milliseconds,
          duration: 800.milliseconds,
          curve: Curves.easeOut,
        )
        .fadeOut(
          delay: 1300.milliseconds,
          duration: 420.milliseconds,
          curve: Curves.easeIn,
        );
  }
}
