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
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

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

  /// 正计时重置前先留痕:已用 ≥1s 才落库(误触不留噪音记录),再清零。
  /// 终点取 `pausedAt ?? now`:暂停中重置不会把暂停时长算进去。
  Future<void> _recordStopwatch(TimerEngine engine) async {
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

  void _onResetTap() {
    final engine = ref.read(timerEngineProvider);
    if (engine.mode == TimerMode.stopwatch && engine.isActive) {
      unawaited(_recordStopwatch(engine));
    }
    ref.read(timerEngineProvider.notifier).reset();
    if (_celebrating) setState(() => _celebrating = false);
    _syncTicker();
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

    return Scaffold(
      backgroundColor: SweetieColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 16),
                _ModeToggle(
                  mode: engine.mode,
                  enabled:
                      status == TimerStatus.idle || status == TimerStatus.finished,
                  onChanged: (mode) =>
                      ref.read(timerEngineProvider.notifier).setMode(mode),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 42,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
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
                    child: _Dial(
                      engine: engine,
                      frames: _frames,
                      tag: selectedTag,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundButton(
                      icon: Icons.refresh_rounded,
                      label: '重置',
                      onTap: _onResetTap,
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
                const SizedBox(height: 32),
              ],
            ),
            if (_celebrating) const _CandyBurst(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 环形计时器
// ---------------------------------------------------------------------------

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
  const _Dial({required this.engine, required this.frames, required this.tag});

  final TimerEngine engine;
  final Listenable frames;
  final String? tag;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: frames,
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
              Container(
                width: 226,
                height: 226,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SweetieColors.white,
                  boxShadow: SweetieTheme.cardShadow(accent),
                ),
              ),
              CustomPaint(
                size: const Size.square(_dialSize),
                painter: _RingPainter(
                  progress: engine.progressAt(now),
                  color: accent,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatClock(shown),
                    style: const TextStyle(
                      fontSize: 46,
                      fontWeight: FontWeight.w800,
                      color: SweetieColors.text,
                      letterSpacing: 1.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _statusLabel(status, engine.mode),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: SweetieColors.textLight,
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
                        color: SweetieColors.soft(SweetieColors.pink),
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
        ..color = SweetieColors.pink.withValues(alpha: 0.14),
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
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
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
          boxShadow: SweetieTheme.buttonShadow(
            active ? SweetieColors.pink : SweetieColors.green,
          ),
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
          color: SweetieColors.yellow.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
          border: Border.all(color: SweetieColors.yellow, width: 1.6),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 18, color: SweetieColors.text),
            SizedBox(width: 4),
            Text(
              '自定义',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: SweetieColors.text,
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
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: SweetieColors.white,
            borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
            boxShadow: SweetieTheme.buttonShadow(SweetieColors.green),
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
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
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
    final accent = widget.primary ? SweetieColors.pink : SweetieColors.green;
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
                boxShadow: SweetieTheme.buttonShadow(accent),
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
            color: SweetieColors.textLight,
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
