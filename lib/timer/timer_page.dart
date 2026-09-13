import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stats/focus_record.dart';
import '../stats/stats_logic.dart';
import '../theme/aurora_background.dart';
import '../theme/sweetie_theme.dart';
import '../widgets/liquid_segmented_control.dart';
import 'timer_dial.dart';
import 'timer_engine.dart';

/// 计时主页:环形计时器 + 标签胶囊 + 开始/暂停/重置。
///
/// 页面不做任何计时累减:运行期间由 [Ticker] 每帧读取「时间戳差值」重绘,
/// 暂停 / 结束后立刻停帧,空闲时不占 CPU。
class TimerPage extends ConsumerStatefulWidget {
  const TimerPage({super.key, this.active = true});

  /// 所在页签是否可见:不可见时暂停背景呼吸(省电)。计时逻辑不受影响。
  final bool active;

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
  void didUpdateWidget(TimerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 页签不可见即停呼吸，回到本页再续；计时 Ticker 不受影响。
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _breath.repeat(reverse: true);
      } else {
        _breath.stop();
      }
    }
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
  /// 用 statusAt 而非 isTicking:倒计时到点后引擎仍 isActive,
  /// 那种状态不该再驱动 Ticker(否则每帧重复判定 finished)。
  void _syncTicker() {
    final ticking = ref.read(timerEngineProvider).statusAt(DateTime.now()) ==
        TimerStatus.running;
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
    _clearCelebration();
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

  /// 庆祝收尾:取消定时器并复位标记,避免旧 Timer 稍后再触发一次无用 setState。
  void _clearCelebration() {
    _celebrateTimer?.cancel();
    if (_celebrating) setState(() => _celebrating = false);
  }

  /// 结束当前一轮:倒计时「提前结束」、正计时「结束」,都会把已用时长记进统计。
  void _onEndTap() {
    final engine = ref.read(timerEngineProvider);
    if (engine.isActive) {
      unawaited(_recordElapsed(engine));
    }
    ref.read(timerEngineProvider.notifier).reset();
    _clearCelebration();
    _syncTicker();
  }

  void _onResetTap() {
    final engine = ref.read(timerEngineProvider);
    if (engine.mode == TimerMode.stopwatch && engine.isActive) {
      unawaited(_recordElapsed(engine));
    }
    ref.read(timerEngineProvider.notifier).reset();
    _clearCelebration();
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
      builder: (_) => _DurationWheelSheet(initial: engine.total),
    );
    if (picked == null || !mounted) return;

    final notifier = ref.read(timerEngineProvider.notifier);
    // 结束后的引擎仍带 startedAt,setDuration 会按「进行中」拦下,先归零再改。
    if (ref.read(timerEngineProvider).isActive) {
      notifier.reset();
      _clearCelebration();
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

  /// 长按标签的底部操作菜单:常驻开关 + 删除。
  ///
  /// 常驻点了就生效(先落状态再关菜单,无二次确认);
  /// 删除仍走原有的 [_confirmRemoveTag] 确认框,菜单先关再弹。
  Future<void> _showTagActions(String tag) async {
    final pinned = ref.read(tagStoreProvider).isPinned(tag);
    final shouldRemove = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: SweetieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(SweetieTheme.radius),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(
                Icons.push_pin_rounded,
                color: SweetieColors.pink,
              ),
              title: Text(pinned ? '取消常驻' : '📌 常驻到标签栏'),
              onTap: () {
                unawaited(
                  ref.read(tagHistoryProvider.notifier).togglePinned(tag),
                );
                Navigator.of(sheetContext).pop(false);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: SweetieColors.pink,
              ),
              title: const Text('删除标签'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (shouldRemove != true || !mounted) return;
    await _confirmRemoveTag(tag);
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
    // TagStore 不是 Listenable,watch 它拿不到更新:靠上面的 tagHistoryProvider
    // 触发重建,这里同步读一次常驻状态即可(排序由存储层保证,UI 不排序)。
    final tagStore = ref.read(tagStoreProvider);
    final selectedTag = ref.watch(selectedTagProvider);
    final status = engine.statusAt(DateTime.now());
    // 计时进行中/暂停中：左侧按钮变为「提前结束」（倒计时）/「结束」（正计时）。
    final bool canEnd =
        status == TimerStatus.running || status == TimerStatus.paused;
    // 计时中锁定标签与模式：不允许中途换 Tag（记录归属会跟着变），
    // 空闲 / 刚结束时才可自由切换。
    final bool canSwitchTag =
        status == TimerStatus.idle || status == TimerStatus.finished;
    // 整页氛围色：与表盘同源，让顶部模式切换/标签/表盘/按钮共享一个背景光。
    final accent = switch (status) {
      TimerStatus.finished => SweetieColors.green,
      TimerStatus.paused => SweetieColors.yellow,
      _ => SweetieColors.pink,
    };

    return Scaffold(
      backgroundColor: SweetieColors.background,
      // 页面没有常驻输入框（输入都在独立 route 的弹窗里），
      // 不让软键盘压缩本页：否则表盘+按钮组被挤到底部溢出（RenderFlex overflow）。
      resizeToAvoidBottomInset: false,
      body: TweenAnimationBuilder<Color?>(
        // 状态色切换时平滑过渡粉/黄/绿，再交给极光背景着色。
        tween: ColorTween(end: accent),
        duration: const Duration(milliseconds: 560),
        curve: Curves.easeOut,
        builder: (context, tintColor, _) {
          final Color tint = tintColor ?? accent;
          return AuroraBackground(
            // 仅本页可见时呼吸；切到阅读/统计页即停，省电。
            running: widget.active,
            tint: tint,
            child: SafeArea(
              child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 12),
                LiquidSegmentedControl(
                  segments: const <LiquidSegment>[
                    LiquidSegment(label: '倒计时'),
                    LiquidSegment(label: '正计时'),
                  ],
                  index: engine.mode == TimerMode.countdown ? 0 : 1,
                  onChanged: (int i) => ref
                      .read(timerEngineProvider.notifier)
                      .setMode(i == 0 ? TimerMode.countdown : TimerMode.stopwatch),
                  enabled: canSwitchTag,
                  height: 44,
                  borderColor: SweetieColors.pink.withValues(alpha: 0.16),
                ),
                const SizedBox(height: 12),
                // 计时中标签条变淡且不吃点击（与模式切换器的禁用观感一致）。
                Opacity(
                  opacity: canSwitchTag ? 1 : 0.45,
                  child: IgnorePointer(
                    ignoring: !canSwitchTag,
                    child: SizedBox(
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
                        pinned: tagStore.isPinned(tag),
                        onTap: () =>
                            ref.read(selectedTagProvider.notifier).select(tag),
                        onLongPress: () => _showTagActions(tag),
                      );
                    },
                  ),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TimerDial(
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
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 时长选择
// ---------------------------------------------------------------------------

/// 甜系滚轮时长面板:时/分/秒 三列滚轮 + 快捷预设胶囊。
///
/// 用 [ListWheelScrollView] 而非 CupertinoPicker:选中粉底条、上下虚化遮罩、
/// 单位小字都要按马卡龙视觉定制,内建组件改不动这些。
/// 每一格跨过刻度都会给一次 [HapticFeedback.selectionClick] 轻反馈。
class _DurationWheelSheet extends StatefulWidget {
  const _DurationWheelSheet({required this.initial});

  final Duration initial;

  @override
  State<_DurationWheelSheet> createState() => _DurationWheelSheetState();
}

class _DurationWheelSheetState extends State<_DurationWheelSheet> {
  /// 单项高度:44 是"看得清、滚得动、按得准"的甜点值。
  static const double _itemExtent = 44;

  /// 最长 23 小时 59 分 59 秒。
  static const int _maxHours = 23;

  static const List<(String, Duration)> _quickPresets = <(String, Duration)>[
    ('15 分钟 · 偷闲', Duration(minutes: 15)),
    ('25 分钟 · 番茄', Duration(minutes: 25)),
    ('45 分钟 · 深度', Duration(minutes: 45)),
  ];

  late int _hours = widget.initial.inHours.clamp(0, _maxHours);
  late int _minutes = widget.initial.inMinutes % 60;
  late int _seconds = widget.initial.inSeconds % 60;

  late final FixedExtentScrollController _hourCtrl =
      FixedExtentScrollController(initialItem: _hours);
  late final FixedExtentScrollController _minuteCtrl =
      FixedExtentScrollController(initialItem: _minutes);
  late final FixedExtentScrollController _secondCtrl =
      FixedExtentScrollController(initialItem: _seconds);

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    _secondCtrl.dispose();
    super.dispose();
  }

  Duration get _picked =>
      Duration(hours: _hours, minutes: _minutes, seconds: _seconds);

  /// 全零不允许确认:0 秒的倒计时没有意义。
  bool get _isZero => _picked == Duration.zero;

  Future<void> _jumpTo(Duration target) async {
    final int h = target.inHours.clamp(0, _maxHours);
    final int m = target.inMinutes % 60;
    final int sec = target.inSeconds % 60;
    setState(() {
      _hours = h;
      _minutes = m;
      _seconds = sec;
    });
    const Duration glide = Duration(milliseconds: 420);
    const Curve curve = Curves.easeOutCubic;
    unawaited(_hourCtrl.animateToItem(h, duration: glide, curve: curve));
    unawaited(_minuteCtrl.animateToItem(m, duration: glide, curve: curve));
    unawaited(_secondCtrl.animateToItem(sec, duration: glide, curve: curve));
  }

  @override
  Widget build(BuildContext context) {
    final Duration picked = _picked;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '倒计时时长',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '${picked.inHours.toString().padLeft(2, '0')} : '
              '${(picked.inMinutes % 60).toString().padLeft(2, '0')} : '
              '${(picked.inSeconds % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: SweetieColors.pink,
                letterSpacing: 2,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            _wheels(),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (final (String label, Duration value) in _quickPresets)
                  _PresetChip(
                    minutes: value.inMinutes,
                    label: label,
                    active: _matches(value),
                    onTap: () => unawaited(_jumpTo(value)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: SweetieColors.pink,
                  foregroundColor: SweetieColors.white,
                  disabledBackgroundColor: SweetieColors.pink.withValues(alpha: 0.28),
                  disabledForegroundColor: SweetieColors.white.withValues(alpha: 0.75),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  shape: const RoundedRectangleBorder(
                    borderRadius: SweetieTheme.cardRadius,
                  ),
                ),
                // 全零禁用(自动虚化):避免 0 秒死循环。
                onPressed: _isZero
                    ? null
                    : () => Navigator.of(context).pop(picked),
                child: Text(_isZero ? '至少选 1 秒' : '确认设定'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _matches(Duration value) => _picked == value;

  /// 三列滚轮 + 贯穿的选中粉底条。
  Widget _wheels() {
    return SizedBox(
      height: _itemExtent * 5,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // 选中指示条:横向贯穿三列的半透明草莓粉。
          Positioned(
            left: 8,
            right: 8,
            height: _itemExtent,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0x1AFF8595),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // 上下虚化:选中行清晰(1.0)、相邻格约 0.36、最远格接近透明,
          // 让"未选中"是真的虚下去(此前不透明带太宽,邻格数字仍然发黑)。
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (Rect rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.42),
                Colors.white,
                Colors.white.withValues(alpha: 0.42),
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.0),
              ],
              stops: const <double>[0.0, 0.18, 0.33, 0.50, 0.67, 0.82, 1.0],
            ).createShader(rect),
            child: Row(
              children: <Widget>[
                _wheel(
                  controller: _hourCtrl,
                  count: _maxHours + 1,
                  unit: '时',
                  onChanged: (int v) => setState(() => _hours = v),
                ),
                _wheel(
                  controller: _minuteCtrl,
                  count: 60,
                  unit: '分',
                  onChanged: (int v) => setState(() => _minutes = v),
                ),
                _wheel(
                  controller: _secondCtrl,
                  count: 60,
                  unit: '秒',
                  onChanged: (int v) => setState(() => _seconds = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int count,
    required String unit,
    required ValueChanged<int> onChanged,
  }) {
    return Expanded(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          ListWheelScrollView.useDelegate(
            controller: controller,
            itemExtent: _itemExtent,
            perspective: 0.002,
            diameterRatio: 1.7,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: (int index) {
              onChanged(index);
              // 每跨过一格给一次轻反馈,滚动"有手感"。
              unawaited(HapticFeedback.selectionClick());
            },
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: count,
              builder: (BuildContext context, int index) => Center(
                child: Text(
                  index.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2D2D2D),
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          // 单位小字:贴在选中行右缘,浅粉不抢数字。
          IgnorePointer(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(
                  unit,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: SweetieColors.pink.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.minutes,
    required this.active,
    required this.onTap,
    this.label,
  });

  final int minutes;

  /// 自定义文案(快捷预设用「15 分钟 · 偷闲」这类词组);为空时回落到「N 分钟」。
  final String? label;
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
          label ?? '$minutes 分钟',
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
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
  });

  final String label;
  final bool active;

  /// 常驻标签:文字前带图钉,未选中时描边更实,方便一眼分辨。
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      // 选中瞬间轻微放大回弹(果冻感):scale 不参与阴影插值,过冲曲线安全。
      child: AnimatedScale(
        scale: active ? 1.05 : 1.0,
        duration: SweetieTheme.animationDuration,
        curve: SweetieTheme.animationCurve,
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
                : SweetieColors.pink
                    .withValues(alpha: pinned ? 0.45 : 0.16),
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pinned) ...[
              Icon(
                Icons.push_pin_rounded,
                size: 12,
                color: active ? SweetieColors.white : SweetieColors.pink,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              '# $label',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: active ? SweetieColors.white : SweetieColors.text,
              ),
            ),
          ],
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
      // 软键盘弹出压缩可用高度:内建滚动化,小屏也不会 BOTTOM OVERFLOWED。
      scrollable: true,
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
// 控制按钮
// ---------------------------------------------------------------------------

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
