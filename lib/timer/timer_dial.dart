import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';

// ---------------------------------------------------------------------------
// 常量与文本格式化
// ---------------------------------------------------------------------------

const double _dialSize = 264;

/// 浅珊瑚:#FF8595 → #FFB3A7 渐变的尾色,兼作整分钟水波纹的颜色。
const Color _kCoral = Color(0xFFFFB3A7);

/// 正计时环的自转周期:9 秒整一圈(8~10 秒区间取中)。
const int _kSpinPeriodMs = 9000;

/// 正计时环占整圈的比例:整圈闭合 —— 正计时没有终点,不留缺口。
const double _kSweepRatio = 1.0;

String _formatClock(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
      : '$minutes:$seconds';
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

/// 已用时长 → 正计时环的自转弧度。
///
/// 相位只由「时间戳差值」推算:空闲停在 12 点、暂停原地冻结、运行 9s 匀速一圈,
/// 恢复后相位连续不跳变;`%` 让数值始终有界,不需要额外的 AnimationController。
double _spinAngle(Duration elapsed) =>
    (elapsed.inMilliseconds % _kSpinPeriodMs) / _kSpinPeriodMs * 2 * math.pi;

// ---------------------------------------------------------------------------
// 表盘
// ---------------------------------------------------------------------------

/// 甜系表盘:呼吸缩放 + 进度环 + 整分钟涟漪。
///
/// 所有时间量都来自 [TimerEngine] 的「时间戳差值」推算,重绘由 [frames] 驱动;
/// 唯一自持的帧源是整分钟水波纹(900ms 一次性动画),跑完立即停,空闲不占 CPU。
class TimerDial extends StatefulWidget {
  const TimerDial({
    super.key,
    required this.engine,
    required this.frames,
    required this.breath,
    required this.tag,
    required this.onTapTime,
  });

  final TimerEngine engine;

  /// 帧计数(每帧自增),驱动倒计时进度与正计时自转重绘。
  final Listenable frames;

  /// 与整页氛围同频的呼吸进度(0..1),驱动表盘缩放与光晕张弛。
  final Animation<double> breath;

  final String? tag;

  /// 点按中央时间文本:倒计时未开始 / 刚结束时弹时长选择。
  final VoidCallback onTapTime;

  @override
  State<TimerDial> createState() => _TimerDialState();
}

class _TimerDialState extends State<TimerDial>
    with SingleTickerProviderStateMixin {
  /// 整分钟涟漪:900ms 从圆心扩散一圈后停在 1(静止态不绘制、不占帧)。
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );

  /// 上一次观察到的整分钟序号;null = 尚未进入「正计时运行中」。
  int? _lastMinute;

  /// 三路合流(帧计数 + 呼吸 + 涟漪)的稳定句柄。
  /// 在 build 里再 merge 会每帧新建并重绑监听,build 热路径上必须复用同一个实例。
  late Listenable _repaint = _mergeRepaint();

  Listenable _mergeRepaint() => Listenable.merge(<Listenable>[
        widget.frames,
        widget.breath,
        _ripple,
      ]);

  @override
  void initState() {
    super.initState();
    widget.frames.addListener(_onFrame);
  }

  @override
  void didUpdateWidget(TimerDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frames, widget.frames)) {
      oldWidget.frames.removeListener(_onFrame);
      widget.frames.addListener(_onFrame);
    }
    if (!identical(oldWidget.frames, widget.frames) ||
        !identical(oldWidget.breath, widget.breath)) {
      _repaint = _mergeRepaint();
    }
  }

  @override
  void dispose() {
    widget.frames.removeListener(_onFrame);
    _ripple.dispose();
    super.dispose();
  }

  /// 只负责一件事:正计时运行中 elapsed 跨过整分钟时放一圈水波纹。
  ///
  /// 离开「正计时运行中」就清空基线,避免暂停/重置后补放一圈。
  void _onFrame() {
    final engine = widget.engine;
    final now = DateTime.now();
    if (engine.mode != TimerMode.stopwatch ||
        engine.statusAt(now) != TimerStatus.running) {
      _lastMinute = null;
      return;
    }
    final minute = engine.elapsedAt(now).inMilliseconds ~/ 60000;
    final last = _lastMinute;
    _lastMinute = minute;
    if (last != null && minute != last) _ripple.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // 三路合流:帧计数(进度/自转)、呼吸(缩放/光晕)、涟漪控制器(水波纹)。
      animation: _repaint,
      builder: (context, _) {
        final engine = widget.engine;
        final now = DateTime.now();
        final status = engine.statusAt(now);
        final countdown = engine.mode == TimerMode.countdown;
        final shown =
            countdown ? engine.remainingAt(now) : engine.elapsedAt(now);
        final accent = switch (status) {
          TimerStatus.finished => SweetieColors.green,
          TimerStatus.paused => SweetieColors.yellow,
          _ => SweetieColors.pink,
        };

        // 呼吸 0..1:表盘在 0.985~1.015 之间极轻微张缩,
        // 外层彩色阴影同步明暗(0.16~0.26)与张弛(blur 14~24)。
        final t = Curves.easeInOutSine.transform(
          widget.breath.value.clamp(0.0, 1.0),
        );
        final glow = SweetieTheme.cardShadow(accent).first.copyWith(
          color: accent.withValues(alpha: 0.16 + 0.10 * t),
          blurRadius: 14.0 + 10.0 * t,
        );

        return Transform.scale(
          scale: 0.985 + 0.03 * t,
          child: SizedBox.square(
            dimension: _dialSize,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
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
                    boxShadow: <BoxShadow>[glow],
                  ),
                ),
                // 整分钟水波纹:叠在盘面之上、环之下,扩散到盘边自然隐去。
                CustomPaint(
                  size: const Size.square(_dialSize),
                  painter: _RipplePainter(t: _ripple.value),
                ),
                CustomPaint(
                  size: const Size.square(_dialSize),
                  painter: _RingPainter(
                    // 倒计时:环从全满向空递减(剩余比例);正计时:定长弧匀速自转。
                    progress: countdown
                        ? 1.0 - engine.progressAt(now)
                        : engine.progressAt(now),
                    color: accent,
                    angle: countdown ? 0.0 : _spinAngle(engine.elapsedAt(now)),
                    countdown: countdown,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onTapTime,
                      child: Semantics(
                        button: true,
                        child: Text(
                          _formatClock(shown),
                          style: const TextStyle(
                            fontSize: 46,
                            fontWeight: FontWeight.w800,
                            color: SweetieColors.text,
                            letterSpacing: 1.5,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
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
                    if (widget.tag != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: SweetieColors.pink.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(
                            SweetieTheme.pillRadius,
                          ),
                        ),
                        child: Text(
                          '# ${widget.tag}',
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
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 画笔
// ---------------------------------------------------------------------------

/// 进度环:倒计时画「剩余比例」渐隐弧,正计时画整圈渐变环 + 匀速自转。
class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.color,
    required this.angle,
    required this.countdown,
  });

  /// 倒计时环长占比 0..1(从满到空);正计时模式下不参与绘制。
  final double progress;

  /// 状态色:底环与糖果珠用它,状态切换一眼可读。
  final Color color;

  /// 正计时自转弧度;倒计时恒 0。
  final double angle;

  final bool countdown;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.07;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 底环:同色低透明度,给"环"一个稳定的存在感。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.14),
    );

    final double start;
    final double sweep;
    final List<Color> colors;
    final Color bead;
    if (countdown) {
      final double left = progress.clamp(0.0, 1.0);
      if (left <= 0) return; // 归零:只留底环。
      start = -math.pi / 2;
      sweep = math.pi * 2 * left;
      // 草莓粉 → 浅珊瑚:从弧头向弧尾晕开。
      colors = const <Color>[SweetieColors.pink, _kCoral];
      bead = color;
    } else {
      start = -math.pi / 2 + angle;
      sweep = math.pi * 2 * _kSweepRatio;
      // 蜜桃粉 → 奶黄 → 薄荷绿 → 回到蜜桃粉:整圈闭合无接缝,跟随自转一起流转。
      colors = const <Color>[
        SweetieColors.pink,
        SweetieColors.yellow,
        SweetieColors.green,
        SweetieColors.pink,
      ];
      bead = SweetieColors.green;
    }

    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: colors,
          transform: GradientRotation(start),
        ).createShader(rect),
    );

    // 弧头糖果珠:白边圆点 + 同色圆心,给环一个"可读的端点"。
    final head = start + sweep;
    final tip = Offset(
      center.dx + math.cos(head) * radius,
      center.dy + math.sin(head) * radius,
    );
    canvas.drawCircle(tip, stroke * 0.66, Paint()..color = SweetieColors.white);
    canvas.drawCircle(tip, stroke * 0.40, Paint()..color = bead);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.angle != angle ||
      oldDelegate.countdown != countdown;
}

/// 整分钟水波纹:从圆心向外扩散的一圈浅粉,随进度变粗变淡直至消失。
class _RipplePainter extends CustomPainter {
  const _RipplePainter({required this.t});

  /// 0..1 的扩散进度(0 与 1 都不绘制)。
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final fade = 1 - t;
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide * 0.44 * Curves.easeOutCubic.transform(t),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 + 8.0 * fade
        ..color = _kCoral.withValues(alpha: 0.45 * fade),
    );
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) => oldDelegate.t != t;
}
