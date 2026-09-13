import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:sweetie_countdown/theme/sweetie_theme.dart';

/// 分段控件的一个选项：一段文字 + 可选图标。
class LiquidSegment {
  const LiquidSegment({required this.label, this.icon});

  /// 选项文字。
  final String label;

  /// 选项图标；为空时该项只显示文字。
  final IconData? icon;
}

/// 液态果冻分段控件。
///
/// 滑块(pill)不做匀速平移：切换时先沿运动方向拉伸到约 1.3 倍宽，
/// 再以 [Curves.easeOutBack] 微超调滑向目标并收缩回弹；
/// 选项文字/图标颜色按滑块覆盖比例连续插值，因此过渡中相邻两项会同时渐变。
///
/// * [expand] 为 true 时各项均分宽度(Row + Expanded)；为 false 时宽度随内容，
///   槽位宽用 TextPainter 预测量「内边距 + 图标 + 文字」得到。
/// * [selectedShowLabel] 为 false 时未选中项只显示图标；槽位始终按完整内容预留，
///   这样切换选中态时整行不会左右跳动。
/// * [enabled] 为 false 时整体 45% 透明并忽略点击。
class LiquidSegmentedControl extends StatefulWidget {
  const LiquidSegmentedControl({
    super.key,
    required this.segments,
    required this.index,
    required this.onChanged,
    this.activeColor = SweetieColors.pink,
    this.activeTextColor = SweetieColors.white,
    this.inactiveTextColor = SweetieColors.text,
    this.background = SweetieColors.white,
    this.borderColor,
    this.height = 44,
    this.enabled = true,
    this.expand = false,
    this.selectedShowLabel = true,
  });

  /// 分段内容，顺序即索引。
  final List<LiquidSegment> segments;

  /// 当前选中索引。
  final int index;

  /// 选中项变化回调；点击已选中项不会触发。
  final ValueChanged<int> onChanged;

  /// 滑块颜色。
  final Color activeColor;

  /// 选中项文字/图标颜色。
  final Color activeTextColor;

  /// 未选中项文字/图标颜色。
  final Color inactiveTextColor;

  /// 控件底色。
  final Color background;

  /// 描边颜色；为空则不画描边。
  final Color? borderColor;

  /// 控件总高度。
  final double height;

  /// 是否可交互。
  final bool enabled;

  /// 是否均分宽度。
  final bool expand;

  /// 选中项是否显示文字。
  final bool selectedShowLabel;

  @override
  State<LiquidSegmentedControl> createState() => _LiquidSegmentedControlState();
}

class _LiquidSegmentedControlState extends State<LiquidSegmentedControl>
    with SingleTickerProviderStateMixin {
  /// 控件内边距、描边宽度与选项左右内边距。
  static const double _padding = 5;
  static const double _borderWidth = 1.2;
  static const double _itemPadding = 16;

  /// 选项内部图标与文字的排版尺寸。
  static const double _iconSize = 18;
  static const double _iconGap = 6;
  static const double _labelSize = 13;
  static const FontWeight _labelWeight = FontWeight.w700;

  /// 拉伸幅度：切换时滑块瞬时宽度 = 槽位宽 × (1 + _stretch)。
  static const double _stretch = 0.3;

  /// 位移起步点：前 25% 只拉伸不移动，之后才滑向目标。
  static const double _moveStart = 0.25;

  /// 滑块时间轴：位置、宽度、形变共用一条曲线。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SweetieTheme.animationDuration,
    value: 1,
  );

  /// 形变：0→1 拉伸(前 32%)，再 1→0 收缩并轻微回弹(后 68%)。
  late final Animation<double> _morph = TweenSequence<double>(
    <TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 32,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 68,
      ),
    ],
  ).animate(_controller);

  /// 上一帧滑块矩形(控件内部坐标)，作为下一次切换动画的起点。
  Rect _last = Rect.zero;

  /// 本次切换的起点矩形；为空表示尚未发生切换。
  Rect? _from;

  @override
  void didUpdateWidget(LiquidSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.segments.length != widget.segments.length) {
      // 从上一帧的位置继续：动画途中再次切换也能顺滑接上。
      _from = _last;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.segments.isEmpty) return SizedBox(height: widget.height);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !widget.enabled,
        child: LayoutBuilder(builder: _buildControl),
      ),
    );
  }

  Widget _buildControl(BuildContext context, BoxConstraints constraints) {
    final int count = widget.segments.length;
    final int index = _clampIndex(widget.index, count);
    final double inset = _padding + (widget.borderColor == null ? 0.0 : _borderWidth);
    final double innerHeight = math.max(0.0, widget.height - 2 * inset);
    final bool fill = widget.expand && constraints.maxWidth.isFinite;

    final TextStyle labelStyle = DefaultTextStyle.of(context).style.copyWith(
          fontSize: _labelSize,
          fontWeight: _labelWeight,
        );

    // 槽位宽度：均分模式把可用宽度切 N 份，否则按内容预测量(超出可用宽度时整体等比压缩)。
    List<double> widths;
    if (fill) {
      widths = List<double>.filled(
        count,
        math.max(0.0, constraints.maxWidth - 2 * inset) / count,
      );
    } else {
      widths = _slotWidths(
        labelStyle,
        MediaQuery.textScalerOf(context),
        Directionality.of(context),
      );
      final double total = _sum(widths);
      final double room = math.max(0.0, constraints.maxWidth - 2 * inset);
      if (total > room && total > 0) {
        final double ratio = room / total;
        widths = <double>[for (final double width in widths) width * ratio];
      }
    }
    final double totalWidth = _sum(widths);

    return Container(
      width: fill ? double.infinity : null,
      height: widget.height,
      padding: const EdgeInsets.all(_padding),
      decoration: BoxDecoration(
        color: widget.background,
        borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
        border: widget.borderColor == null
            ? null
            : Border.all(color: widget.borderColor!, width: _borderWidth),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final Rect pill = _pillRect(widths, index, innerHeight, totalWidth);
          return SizedBox(
            width: totalWidth,
            height: innerHeight,
            child: Stack(
              children: <Widget>[
                // 滑块在选项下层，先画。
                Positioned(
                  left: pill.left,
                  top: 0,
                  width: pill.width,
                  height: innerHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.activeColor,
                      borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
                      boxShadow: SweetieTheme.pillGlow(color: widget.activeColor, active: true),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: _items(widths, index, innerHeight, pill, labelStyle),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 当前帧滑块矩形：位置在起点与目标之间插值，宽度再叠加沿运动方向的拉伸。
  Rect _pillRect(List<double> widths, int index, double height, double totalWidth) {
    final double targetLeft = _offsetOf(widths, index);
    final double targetWidth = widths[index];

    // 前 25% 时间只拉伸，之后 easeOutBack 微超调滑向目标。
    final double progress = _controller.value;
    final double travel = progress <= _moveStart
        ? 0.0
        : Curves.easeOutBack.transform((progress - _moveStart) / (1 - _moveStart));
    final Rect from = _from ?? Rect.fromLTWH(targetLeft, 0, targetWidth, height);
    final double baseLeft = from.left + (targetLeft - from.left) * travel;
    final double baseWidth = from.width + (targetWidth - from.width) * travel;

    // 拉伸沿运动方向生长：向右移动时左缘不动、宽度向右扩，向左移动时相反。
    final double stretch = baseWidth * _stretch * _morph.value;
    final bool rightward = targetLeft >= from.left;
    final double width = math.min(baseWidth + stretch, totalWidth);
    final double rawLeft = rightward ? baseLeft : baseLeft - stretch;
    final double left = math.max(0.0, math.min(rawLeft, math.max(0.0, totalWidth - width)));

    final Rect pill = Rect.fromLTWH(left, 0, width, height);
    _last = pill;
    return pill;
  }

  Widget _items(
    List<double> widths,
    int index,
    double height,
    Rect pill,
    TextStyle labelStyle,
  ) {
    final List<Widget> children = <Widget>[];
    double left = 0;
    for (int i = 0; i < widths.length; i++) {
      final double width = widths[i];
      final LiquidSegment segment = widget.segments[i];
      final bool active = i == index;

      // 颜色按滑块覆盖比例插值，而不是选中态硬切。
      final double overlap =
          math.max(0.0, math.min(pill.right, left + width) - math.max(pill.left, left));
      final double cover = width <= 0 ? 0.0 : math.min(1.0, overlap / width);
      final Color color = Color.lerp(widget.inactiveTextColor, widget.activeTextColor, cover)!;

      children.add(SizedBox(
        width: width,
        height: height,
        child: _SegmentItem(
          segment: segment,
          style: labelStyle.copyWith(color: color),
          iconSize: _iconSize,
          gap: _iconGap,
          padding: _itemPadding,
          showLabel: widget.selectedShowLabel || active || segment.icon == null,
          selected: active,
          onTap: () {
            if (i != widget.index) widget.onChanged(i);
          },
        ),
      ));
      left += width;
    }
    return widget.expand
        ? Row(children: <Widget>[for (final Widget item in children) Expanded(child: item)])
        : Row(children: children);
  }

  /// 非均分模式：用 TextPainter 预测量每段自然宽度。
  List<double> _slotWidths(TextStyle style, TextScaler scaler, TextDirection direction) {
    return <double>[
      for (final LiquidSegment segment in widget.segments)
        _slotWidth(segment, style, scaler, direction),
    ];
  }

  double _slotWidth(
    LiquidSegment segment,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    double width = 2 * _itemPadding;
    if (segment.icon != null) {
      width += _iconSize;
      if (segment.label.isNotEmpty) width += _iconGap;
    }
    if (segment.label.isEmpty) return width;

    final TextPainter painter = TextPainter(
      text: TextSpan(text: segment.label, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    width += painter.width;
    painter.dispose();
    return width;
  }

  double _offsetOf(List<double> widths, int index) {
    double left = 0;
    for (int i = 0; i < index; i++) {
      left += widths[i];
    }
    return left;
  }

  double _sum(List<double> values) {
    double total = 0;
    for (final double value in values) {
      total += value;
    }
    return total;
  }

  int _clampIndex(int value, int length) {
    if (value < 0) return 0;
    return value >= length ? length - 1 : value;
  }
}

// ---------------------------------------------------------------------------
// 单个选项
// ---------------------------------------------------------------------------

/// 单个选项：按下缩到 0.95，松手用弹性曲线回弹 1.0。
class _SegmentItem extends StatefulWidget {
  const _SegmentItem({
    required this.segment,
    required this.style,
    required this.iconSize,
    required this.gap,
    required this.padding,
    required this.showLabel,
    required this.selected,
    required this.onTap,
  });

  final LiquidSegment segment;
  final TextStyle style;
  final double iconSize;
  final double gap;
  final double padding;
  final bool showLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegmentItem> createState() => _SegmentItemState();
}

class _SegmentItemState extends State<_SegmentItem> with SingleTickerProviderStateMixin {
  /// 0 = 原始尺寸，1 = 按下 0.95；松手用 animateBack + elasticOut 直接驱动数值回弹。
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _pressDown() {
    _press.animateTo(1, duration: const Duration(milliseconds: 110), curve: Curves.easeOut);
  }

  void _pressUp() {
    _press.animateBack(0, duration: const Duration(milliseconds: 420), curve: Curves.elasticOut);
  }

  @override
  Widget build(BuildContext context) {
    final LiquidSegment segment = widget.segment;
    final IconData? icon = segment.icon;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _pressDown(),
        onTapUp: (_) => _pressUp(),
        onTapCancel: _pressUp,
        child: AnimatedBuilder(
          animation: _press,
          builder: (BuildContext context, Widget? child) =>
              Transform.scale(scale: 1 - 0.05 * _press.value, child: child),
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.padding),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null)
                    Icon(icon, size: widget.iconSize, color: widget.style.color),
                  if (icon != null && widget.showLabel) SizedBox(width: widget.gap),
                  if (widget.showLabel)
                    Flexible(
                      child: Text(
                        segment.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: widget.style,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
