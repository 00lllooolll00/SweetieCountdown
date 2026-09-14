import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../theme/sweetie_theme.dart';
import 'reading_service.dart';

/// 启动页：随机一句语录上浮 + 渐显（1.2s 内浮现完），随后稳定停留 3s 再进主页；
/// 点击任意处随时跳过。
///
/// 两种接法都支持：
///  * `SplashPage(next: (_) => const SweetieHomeShell())` —— 3s 后 pushReplacement；
///  * `SplashPage(onFinished: () => setState(() => _showSplash = false))` ——
///    主壳自己当 overlay 控制切换。
/// 语录读 assets/quotes.json（main 里 [preloadQuotes] 预热），
/// 资源缺失时用 [fallbackQuotes] 兜底，绝不白屏。
class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    this.next,
    this.duration = const Duration(seconds: 3),
    this.onFinished,
    this.quote,
  });

  /// 停留时长（默认 3s，或点击跳过）之后进入的主界面。
  final WidgetBuilder? next;

  /// 浮现动效完成后的【稳定停留时长】。
  /// 实际总时长 = 浮现动效([_introDuration]) + 本值。
  final Duration duration;

  /// 主壳自己控制切换时用（overlay 模式，不做路由跳转）。
  final VoidCallback? onFinished;

  /// 注入指定台词（测试 / 预览）。
  final DailyQuote? quote;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  late DailyQuote _quote;
  Timer? _timer;
  bool _leaving = false;

  /// 卡片浮现动效时长:取停留时长的一半且不超过 1.2s。
  /// 动效若占满整个停留时间,卡片会"一直在动就被切走",主观上就是"闪一下"。
  Duration get _introDuration {
    final Duration half = widget.duration ~/ 2;
    return half < const Duration(milliseconds: 1200)
        ? half
        : const Duration(milliseconds: 1200);
  }

  @override
  void initState() {
    super.initState();
    _quote = widget.quote ?? randomQuote();
    if (widget.quote == null && preloadedQuotes.isEmpty) {
      // main 若没预热，这里补一次；失败保持内置兜底。
      unawaited(_loadQuotes());
    }
    // 总停留 = 浮现动效 + 稳定显示:用户要的是"浮现完成后稳住 3 秒",
    // 而不是"从出现到切走一共 3 秒"。
    _timer = Timer(_introDuration + widget.duration, _leave);
  }

  Future<void> _loadQuotes() async {
    await preloadQuotes();
    if (!mounted) return;
    final DailyQuote quote = randomQuote();
    if (quote.en != _quote.en) setState(() => _quote = quote);
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();

    final VoidCallback? onFinished = widget.onFinished;
    if (onFinished != null) {
      onFinished();
      return;
    }

    final WidgetBuilder? next = widget.next;
    if (next != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: next),
      );
      return;
    }

    // 既没给 next 也没给 onFinished：走 main.dart 注册的 '/home' 命名路由，
    // 找不到就退回上一页——绝不停在白屏。
    final NavigatorState? navigator = Navigator.maybeOf(context);
    if (navigator == null) return;
    try {
      unawaited(navigator.pushReplacementNamed<Object?, Object?>('/home'));
    } catch (_) {
      if (navigator.canPop()) navigator.pop();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _quoteCard() {
    final DailyQuote quote = _quote;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: SweetieTheme.cardRadius,
        boxShadow: <BoxShadow>[
          ...SweetieTheme.cardShadow(SweetieColors.yellow),
          ...SweetieTheme.cardShadow(),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            '“',
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 42,
              height: 1,
              color: SweetieColors.pink,
            ),
          ),
          Text(
            quote.en,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'serif',
              fontSize: 21,
              height: 1.6,
              color: SweetieColors.text,
              letterSpacing: 0.2,
            ),
          ),
          if (quote.zh.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              quote.zh,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.8,
                color: SweetieColors.text.withAlpha(0xC7),
                letterSpacing: 0.4,
              ),
            ),
          ],
          if (quote.author.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              '— ${quote.author}',
              style: const TextStyle(
                fontSize: 12.5,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w500,
                color: SweetieColors.textLight,
              ),
            ),
          ],
        ],
      ),
    )
        .animate(key: ValueKey<String>(quote.en))
        .fadeIn(duration: _introDuration, curve: Curves.easeOut)
        .slideY(
          begin: 0.32,
          end: 0,
          duration: _introDuration,
          curve: Curves.easeOutBack,
        );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _leave,
      child: Container(
        color: SweetieColors.background,
        child: Stack(
          children: <Widget>[
            Positioned(
              top: -70,
              right: -50,
              child: _Blob(
                color: SweetieColors.soft(SweetieColors.pink),
                size: 220,
              ),
            ),
            Positioned(
              bottom: -80,
              left: -60,
              child: _Blob(
                color: SweetieColors.soft(SweetieColors.yellow),
                size: 240,
              ),
            ),
            Positioned(
              top: 160,
              left: -90,
              child: _Blob(
                color: SweetieColors.soft(SweetieColors.green),
                size: 190,
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _quoteCard(),
                    const SizedBox(height: 26),
                    Text(
                      '轻点任意处跳过',
                      style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 2,
                        color: SweetieColors.text.withAlpha(0x73),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 36,
              child: Text(
                'Sweetie Countdown',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                  color: SweetieColors.pink.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 背景柔光斑。
class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(color: color, blurRadius: 60, spreadRadius: 10),
        ],
      ),
    );
  }
}
