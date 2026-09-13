import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:sweetie_countdown/reading/reading_page.dart';
import 'package:sweetie_countdown/reading/reading_service.dart';
import 'package:sweetie_countdown/reading/splash_page.dart';
import 'package:sweetie_countdown/stats/stats_logic.dart';
import 'package:sweetie_countdown/stats/stats_page.dart';
import 'package:sweetie_countdown/theme/sweetie_theme.dart';
import 'package:sweetie_countdown/timer/timer_engine.dart';
import 'package:sweetie_countdown/timer/timer_page.dart';
import 'package:sweetie_countdown/widgets/liquid_segmented_control.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 唯一初始化点：Hive 沙箱 + 各模块的箱（openBox 幂等，模块只读写不 init）。
  await Hive.initFlutter();
  await initStatsStorage(); // 注册 FocusRecordAdapter(typeId 7) 并打开 focus_records
  await openTagBox(); // 打开 sweetie_tags
  await Hive.openBox<String>(ReadingService.cacheBoxName); // 打开 reading_cache
  await Hive.openBox<String>(ReadingService.favoriteBoxName); // 打开 reading_favorites
  await preloadQuotes(); // 治愈短句预热，失败不抛

  runApp(const ProviderScope(child: SweetieApp()));
}

class SweetieApp extends StatelessWidget {
  const SweetieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SweetieCountdown',
      debugShowCheckedModeBanner: false,
      theme: SweetieTheme.toThemeData(),
      home: SplashPage(next: (BuildContext context) => const SweetieHomeShell()),
      onGenerateRoute: (RouteSettings settings) {
        if (settings.name == '/home') {
          return MaterialPageRoute<void>(builder: (_) => const SweetieHomeShell());
        }
        return null;
      },
    );
  }
}

/// 主壳：底部马卡龙胶囊导航 + 三页 IndexedStack（专注 / 阅读 / 统计）。
class SweetieHomeShell extends StatefulWidget {
  const SweetieHomeShell({super.key});

  @override
  State<SweetieHomeShell> createState() => _SweetieHomeShellState();
}

class _SweetieHomeShellState extends State<SweetieHomeShell> {
  static const List<_NavItem> _items = <_NavItem>[
    _NavItem(label: '专注', icon: Icons.timer_rounded, color: SweetieColors.pink),
    _NavItem(label: '阅读', icon: Icons.menu_book_rounded, color: SweetieColors.yellow),
    _NavItem(label: '统计', icon: Icons.insights_rounded, color: SweetieColors.green),
  ];

  int _index = 0;

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 键盘只在弹窗里用（页面无输入框）；若按默认压缩 body，
      // 会把专注页的表盘+按钮组挤爆（RenderFlex overflow 黄黑条纹）。
      resizeToAvoidBottomInset: false,
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          // 只给专注页传可见性：不可见时暂停背景呼吸（省电），计时逻辑不受影响。
          TimerPage(active: _index == 0),
          const ReadingPage(),
          const StatsPage(),
        ],
      ),
      bottomNavigationBar: _MacaronNavBar(
        items: _items,
        currentIndex: _index,
        onTap: _select,
      ),
    );
  }
}

class _NavItem {
  const _NavItem({required this.label, required this.icon, required this.color});

  final String label;
  final IconData icon;
  final Color color;
}

class _MacaronNavBar extends StatelessWidget {
  const _MacaronNavBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<_NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: DecoratedBox(
        // 阴影由外层提供:组件本体只负责"滑块 + 内容"。
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SweetieTheme.pillRadius),
          boxShadow: SweetieTheme.cardShadow(),
        ),
        child: LiquidSegmentedControl(
          segments: <LiquidSegment>[
            for (final _NavItem it in items)
              LiquidSegment(label: it.label, icon: it.icon),
          ],
          index: currentIndex,
          onChanged: onTap,
          // 滑块随选中项换色(粉/黄/绿),保留马卡龙三色语言。
          activeColor: items[currentIndex].color,
          expand: true,
          // 未选中只留图标,选中才展开文字(与旧导航一致)。
          selectedShowLabel: false,
          height: 52,
        ),
      ),
    );
  }
}

