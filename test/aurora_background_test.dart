import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sweetie_countdown/theme/aurora_background.dart';

/// 极光层内所有 Transform 的矩阵（3 块柔光各一个 translate + 一个 scale）。
List<List<double>> _blobTransforms(WidgetTester tester) => tester
    .widgetList<Transform>(
      find.descendant(of: find.byType(AuroraBackground), matching: find.byType(Transform)),
    )
    .map((Transform t) => t.transform.storage.toList())
    .toList();

/// 柔焦层内 3 块色团的填充色。
List<Color?> _blobColors(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: find.byType(ImageFiltered), matching: find.byType(DecoratedBox)),
    )
    .map((DecoratedBox d) => (d.decoration as BoxDecoration).color)
    .toList();

/// 常驻动画不能用 pumpAndSettle（永远安定不了），固定时长逐帧推进。
Future<void> _pumpFrames(WidgetTester tester, {required int frames, required Duration step}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

void main() {
  group('AuroraBackground', () {
    testWidgets('渲染 child', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AuroraBackground(child: Center(child: Text('极光前景')))),
      );

      expect(find.text('极光前景'), findsOneWidget);
    });

    testWidgets('running=true 时连续推进多帧不抛异常，且色团在移动', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AuroraBackground(child: Center(child: Text('极光前景')))),
      );
      final List<List<double>> before = _blobTransforms(tester);

      await _pumpFrames(tester, frames: 30, step: const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('极光前景'), findsOneWidget);
      expect(_blobTransforms(tester), isNot(equals(before)));
    });

    testWidgets('running=false 时冻结在当前相位，child 仍在且无异常', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AuroraBackground(running: false, child: Center(child: Text('静止前景'))),
        ),
      );
      final List<List<double>> frozen = _blobTransforms(tester);

      await _pumpFrames(tester, frames: 20, step: const Duration(milliseconds: 250));

      expect(tester.takeException(), isNull);
      expect(find.text('静止前景'), findsOneWidget);
      expect(_blobTransforms(tester), equals(frozen));
    });

    testWidgets('切换 tint 重建不抛异常，且色团随之变色', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AuroraBackground(tint: Colors.pink, child: Center(child: Text('极光前景'))),
        ),
      );
      final List<Color?> pink = _blobColors(tester);

      await tester.pumpWidget(
        const MaterialApp(
          home: AuroraBackground(tint: Colors.blue, child: Center(child: Text('极光前景'))),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('极光前景'), findsOneWidget);
      expect(_blobColors(tester), isNot(equals(pink)));
    });
  });
}
