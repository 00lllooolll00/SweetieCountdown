import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sweetie_countdown/widgets/liquid_segmented_control.dart';

// 组件带常驻滑块动画 + 按压回弹动画，禁止 pumpAndSettle；统一用固定时长推进。
const Color _pillColor = Color(0xFF112233);
const Color _activeText = Colors.white;
const Color _inactiveText = Colors.black;
const Color _background = Color(0xFFF5F5F5);

const List<LiquidSegment> _twoSegments = <LiquidSegment>[
  LiquidSegment(label: '专注'),
  LiquidSegment(label: '休息'),
];

/// 固定时长推进：覆盖滑块 320ms 与按压回弹 420ms 两条动画。
Future<void> _advance(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Widget _host({
  required int index,
  List<LiquidSegment> segments = _twoSegments,
  ValueChanged<int>? onChanged,
  bool enabled = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: LiquidSegmentedControl(
          segments: segments,
          index: index,
          enabled: enabled,
          onChanged: onChanged ?? (int value) {},
          activeColor: _pillColor,
          activeTextColor: _activeText,
          inactiveTextColor: _inactiveText,
          background: _background,
        ),
      ),
    ),
  );
}

/// 滑块：控件内唯一以 [activeColor] 着色的 DecoratedBox。
Finder _pillFinder() => find.byWidgetPredicate((Widget widget) {
      if (widget is! DecoratedBox) return false;
      final Decoration decoration = widget.decoration;
      return decoration is BoxDecoration && decoration.color == _pillColor;
    });

/// 命中判断：色值允许浮点插值误差，用分量近似比较。
bool _closeTo(Color actual, Color expected) {
  return (actual.a - expected.a).abs() < 0.01 &&
      (actual.r - expected.r).abs() < 0.01 &&
      (actual.g - expected.g).abs() < 0.01 &&
      (actual.b - expected.b).abs() < 0.01;
}

Color _labelColor(WidgetTester tester, String label) {
  return tester.widget<Text>(find.text(label)).style!.color!;
}

double _distanceToLabel(double x, WidgetTester tester, String label) {
  return (x - tester.getCenter(find.text(label)).dx).abs();
}

void main() {
  testWidgets('初始 index=0：两段文字都渲染，滑块停在首段', (WidgetTester tester) async {
    await tester.pumpWidget(_host(index: 0));
    await _advance(tester);

    expect(find.text('专注'), findsOneWidget);
    expect(find.text('休息'), findsOneWidget);
    expect(_pillFinder(), findsOneWidget);

    final double pillCenter = tester.getCenter(_pillFinder()).dx;
    expect(
      _distanceToLabel(pillCenter, tester, '专注') <
          _distanceToLabel(pillCenter, tester, '休息'),
      isTrue,
      reason: '滑块中心应更靠近首段文字',
    );
  });

  testWidgets('点击第二段 → onChanged 收到 1；点击已选中项不触发',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    await tester.pumpWidget(_host(index: 0, onChanged: calls.add));
    await _advance(tester);

    await tester.tap(find.text('休息'));
    await _advance(tester);

    expect(calls, <int>[1]);

    // 父级没换 index，再点首段(仍为选中项)：文档约定不回调。
    await tester.tap(find.text('专注'));
    await _advance(tester);

    expect(calls, <int>[1]);
  });

  testWidgets('enabled=false：整体变淡且忽略点击，onChanged 不触发',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    await tester.pumpWidget(_host(index: 0, enabled: false, onChanged: calls.add));
    await _advance(tester);

    final Finder opacity = find.descendant(
      of: find.byType(LiquidSegmentedControl),
      matching: find.byType(Opacity),
    );
    expect(opacity, findsOneWidget);
    expect(tester.widget<Opacity>(opacity).opacity, 0.45);

    await tester.tap(find.text('休息'), warnIfMissed: false);
    await _advance(tester);

    expect(calls, isEmpty);
  });

  testWidgets('带 icon 的选项渲染 Icon，并跟随选中态着色', (WidgetTester tester) async {
    const List<LiquidSegment> segments = <LiquidSegment>[
      LiquidSegment(label: '专注', icon: Icons.timer_outlined),
      LiquidSegment(label: '休息', icon: Icons.coffee_outlined),
    ];
    await tester.pumpWidget(_host(index: 0, segments: segments));
    await _advance(tester);

    expect(find.byIcon(Icons.timer_outlined), findsOneWidget);
    expect(find.byIcon(Icons.coffee_outlined), findsOneWidget);

    expect(
      _closeTo(tester.widget<Icon>(find.byIcon(Icons.timer_outlined)).color!, _activeText),
      isTrue,
      reason: '选中项图标用选中色',
    );
    expect(
      _closeTo(tester.widget<Icon>(find.byIcon(Icons.coffee_outlined)).color!, _inactiveText),
      isTrue,
      reason: '未选中项图标用未选中色',
    );
  });

  testWidgets('index 变化重建：不抛异常、滑块与选中态切换、onChanged 不被误触发',
      (WidgetTester tester) async {
    final List<int> calls = <int>[];
    await tester.pumpWidget(_host(index: 0, onChanged: calls.add));
    await _advance(tester);

    final double pillBefore = tester.getCenter(_pillFinder()).dx;
    expect(_closeTo(_labelColor(tester, '专注'), _activeText), isTrue);

    await tester.pumpWidget(_host(index: 1, onChanged: calls.add));
    await _advance(tester);

    expect(tester.takeException(), isNull);
    expect(calls, isEmpty);

    final double pillAfter = tester.getCenter(_pillFinder()).dx;
    expect(pillAfter > pillBefore, isTrue, reason: '滑块应向第二段移动');
    expect(
      _distanceToLabel(pillAfter, tester, '休息') <
          _distanceToLabel(pillAfter, tester, '专注'),
      isTrue,
      reason: '滑块中心应更靠近第二段文字',
    );
    expect(_closeTo(_labelColor(tester, '休息'), _activeText), isTrue);
    expect(_closeTo(_labelColor(tester, '专注'), _inactiveText), isTrue);
  });
}
