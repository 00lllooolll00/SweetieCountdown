import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';

// ---------------------------------------------------------------------------
// 常量：底色 / 柔焦 / 节奏 / 呼吸区间
// ---------------------------------------------------------------------------

/// 极光面板底色：奶霜白。
const Color _kBaseColor = Color(0xFFFFFDFB);

/// 柔焦半径：50 的高斯模糊——足够把边缘晕开，又保住「几团光」的聚拢度。
const double _kBlurSigma = 50;

/// 极光一个完整周期：10s 匀速（8~12s 区间取中），周期内李萨如轨迹正好闭合。
const Duration _kPeriod = Duration(seconds: 10);

/// 呼吸缩放区间。
const double _kBreathMin = 0.9;
const double _kBreathMax = 1.15;

/// tint 叠加在色块 A 上的透明度。
const double _kTintStrength = 0.06;

// ---------------------------------------------------------------------------
// 色块参数
// ---------------------------------------------------------------------------

/// 单块柔光的静态描述：尺寸、基准位置（面板比例）、李萨如频率/相位、漂移幅度与呼吸节奏。
class _AuroraBlob {
  const _AuroraBlob({
    required this.color,
    required this.alpha,
    required this.size,
    required this.center,
    required this.freqX,
    required this.freqY,
    required this.phaseX,
    required this.phaseY,
    required this.driftX,
    required this.driftY,
    required this.breathFreq,
    required this.breathPhase,
  });

  /// 不透明基色，绘制时再套 [alpha]。
  final Color color;

  /// 基础透明度。
  final double alpha;

  /// 椭圆尺寸（逻辑像素，380~520）。
  final Size size;

  /// 基准中心，取面板宽高的比例。
  final Offset center;

  /// 李萨如横向频率（每个周期的往返次数）。
  final double freqX;

  /// 李萨如纵向频率。
  final double freqY;

  /// 横向相位。
  final double phaseX;

  /// 纵向相位。
  final double phaseY;

  /// 横向漂移幅度（面板宽度的比例）。
  final double driftX;

  /// 纵向漂移幅度（面板高度的比例）。
  final double driftY;

  /// 呼吸频率（每个周期的次数）。
  final double breathFreq;

  /// 呼吸相位。
  final double breathPhase;
}

/// 三块柔光：位置、频率与相位全部错开，避免同步呼吸。
const List<_AuroraBlob> _kBlobs = <_AuroraBlob>[
  // A：粉，偏左上；tint 会以 6% 透明度叠加在它上面。
  _AuroraBlob(
    color: Color(0xFFFFD6DE),
    alpha: 0.62,
    size: Size(560, 500),
    center: Offset(0.28, 0.30),
    freqX: 1.0,
    freqY: 2.0,
    phaseX: 0.0,
    phaseY: 0.6,
    driftX: 0.14,
    driftY: 0.10,
    breathFreq: 1.0,
    breathPhase: 0.0,
  ),
  // B：浅粉，偏右。
  _AuroraBlob(
    color: Color(0xFFFFE5EC),
    alpha: 0.55,
    size: Size(500, 540),
    center: Offset(0.74, 0.36),
    freqX: 1.0,
    freqY: 2.0,
    phaseX: 2.1,
    phaseY: 3.4,
    driftX: 0.12,
    driftY: 0.09,
    breathFreq: 1.0,
    breathPhase: 2.2,
  ),
  // C：暖杏，偏底部，频率比前两块高一点，游走更“活”。
  _AuroraBlob(
    color: Color(0xFFFFF0E6),
    alpha: 0.46,
    size: Size(440, 460),
    center: Offset(0.50, 0.76),
    freqX: 2.0,
    freqY: 3.0,
    phaseX: 4.2,
    phaseY: 1.1,
    driftX: 0.10,
    driftY: 0.12,
    breathFreq: 2.0,
    breathPhase: 3.6,
  ),
];

// ---------------------------------------------------------------------------
// 极光背景
// ---------------------------------------------------------------------------

/// 有机极光背景：奶霜白底上三块柔焦色团沿李萨如轨迹缓慢漂移 + 呼吸缩放。
///
/// [child] 叠在色块之上；背景层单独包 [RepaintBoundary]，前景重绘不会带着极光一起重画。
/// [running] 为 false 时暂停动画（[AnimationController.stop]），页面不可见时可省电。
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({
    super.key,
    required this.child,
    this.running = true,
    this.tint = SweetieColors.pink,
  });

  /// 叠在极光之上的前景内容。
  final Widget child;

  /// 是否播放漂移/呼吸动画；false 时冻结在当前相位。
  final bool running;

  /// 主题色调：仅以 6% 透明度轻扫色块 A，整体粉调不变。
  final Color tint;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: _kPeriod);

  @override
  void initState() {
    super.initState();
    if (widget.running) _controller.repeat();
  }

  @override
  void didUpdateWidget(AuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.running == oldWidget.running) return;
    if (widget.running) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 解析绘制色：色块 A 先叠 6% 的 [AuroraBackground.tint]，再套各自的基础透明度。
  List<Color> _resolveColors() {
    return <Color>[
      Color.alphaBlend(widget.tint.withValues(alpha: _kTintStrength), _kBlobs[0].color)
          .withValues(alpha: _kBlobs[0].alpha),
      _kBlobs[1].color.withValues(alpha: _kBlobs[1].alpha),
      _kBlobs[2].color.withValues(alpha: _kBlobs[2].alpha),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = _resolveColors();
    return Stack(
      children: <Widget>[
        // 背景层：奶霜白底 + 三块柔焦极光，独立 RepaintBoundary 与前景隔离。
        Positioned.fill(
          child: RepaintBoundary(
            child: ColoredBox(
              color: _kBaseColor,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Size panel = constraints.biggest;
                  return ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: _kBlurSigma, sigmaY: _kBlurSigma),
                    child: Stack(
                      children: <Widget>[
                        for (int i = 0; i < _kBlobs.length; i++)
                          _buildBlob(_kBlobs[i], colors[i], panel),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }

  /// 单块柔光：定位与尺寸静态，只有 [Transform] 逐帧更新，不触发布局。
  Widget _buildBlob(_AuroraBlob blob, Color color, Size panel) {
    return Positioned(
      left: blob.center.dx * panel.width - blob.size.width / 2,
      top: blob.center.dy * panel.height - blob.size.height / 2,
      child: AnimatedBuilder(
        animation: _controller,
        child: SizedBox(
          width: blob.size.width,
          height: blob.size.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.all(
                Radius.elliptical(blob.size.width / 2, blob.size.height / 2),
              ),
            ),
          ),
        ),
        builder: (BuildContext context, Widget? child) {
          final double t = _controller.value * 2 * math.pi;
          // 李萨如轨迹：sin/cos 取不同频率与相位，横向与纵向各自游走。
          final double driftX = math.sin(t * blob.freqX + blob.phaseX) * blob.driftX * panel.width;
          final double driftY = math.cos(t * blob.freqY + blob.phaseY) * blob.driftY * panel.height;
          // 呼吸缩放 0.9~1.15，相位与漂移错开。
          final double wave = 0.5 + 0.5 * math.sin(t * blob.breathFreq + blob.breathPhase);
          final double breath = _kBreathMin + (_kBreathMax - _kBreathMin) * wave;
          return Transform.translate(
            offset: Offset(driftX, driftY),
            child: Transform.scale(scale: breath, child: child),
          );
        },
      ),
    );
  }
}
