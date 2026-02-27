import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/widgets/terminal_pane.dart';
import 'package:iroh_ssh_app/widgets/terminal_tab.dart';
import 'package:xterm/xterm.dart';

double _terminalFontSize(WidgetTester tester) {
  final view = tester.widget<TerminalView>(find.byType(TerminalView));
  return view.textStyle.fontSize;
}

/// Perform a pinch gesture (two-finger scale) on the given finder.
Future<void> _pinch(
  WidgetTester tester,
  Finder target, {
  required double scale,
}) async {
  final center = tester.getCenter(target);

  // Start both pointers with enough separation that the gesture recognizer
  // picks up a scale change.
  final offset = const Offset(50, 0);
  final start1 = center - offset;
  final start2 = center + offset;
  final end1 = center - offset * scale;
  final end2 = center + offset * scale;

  final gesture1 = await tester.startGesture(start1);
  await tester.pump();
  final gesture2 = await tester.startGesture(start2);
  await tester.pump();

  // Move in steps to let the gesture recognizer detect a scale change.
  const steps = 20;
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    await gesture1.moveTo(Offset.lerp(start1, end1, t)!);
    await gesture2.moveTo(Offset.lerp(start2, end2, t)!);
    await tester.pump(const Duration(milliseconds: 16));
  }

  await gesture1.up();
  await gesture2.up();
  await tester.pumpAndSettle();
}

Widget _terminalPaneApp({
  required Terminal terminal,
  double fontSize = 14.0,
  ValueChanged<double>? onFontSizeChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: TerminalPane(
          terminal: terminal,
          fontSize: fontSize,
          onFontSizeChanged: onFontSizeChanged,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('pinch-to-zoom changes terminal font size', (tester) async {
    final terminal = Terminal(maxLines: 100);
    double? reportedSize;

    await tester.pumpWidget(_terminalPaneApp(
      terminal: terminal,
      fontSize: 14.0,
      onFontSizeChanged: (size) => reportedSize = size,
    ));
    await tester.pumpAndSettle();

    expect(_terminalFontSize(tester), 14.0);

    // Pinch out (zoom in) — scale > 1
    await _pinch(tester, find.byType(TerminalView), scale: 1.5);

    final sizeAfterZoomIn = _terminalFontSize(tester);
    expect(sizeAfterZoomIn, greaterThan(14.0));
    expect(sizeAfterZoomIn, equals(sizeAfterZoomIn.roundToDouble()),
        reason: 'Font size should be rounded to whole number');
    expect(reportedSize, sizeAfterZoomIn);
  });

  testWidgets('font size is clamped within 8–24 range', (tester) async {
    final terminal = Terminal(maxLines: 100);

    await tester.pumpWidget(_terminalPaneApp(
      terminal: terminal,
      fontSize: 10.0,
    ));
    await tester.pumpAndSettle();

    // Pinch in aggressively (zoom out) — try to go below 8
    await _pinch(tester, find.byType(TerminalView), scale: 0.3);
    expect(_terminalFontSize(tester), greaterThanOrEqualTo(8.0));

    // Reset with larger font and zoom in aggressively — try to go above 24
    await tester.pumpWidget(_terminalPaneApp(
      terminal: terminal,
      fontSize: 20.0,
    ));
    await tester.pumpAndSettle();

    await _pinch(tester, find.byType(TerminalView), scale: 3.0);
    expect(_terminalFontSize(tester), lessThanOrEqualTo(24.0));
  });

  testWidgets('each tab maintains independent font size', (tester) async {
    final tabKey1 = GlobalKey<TerminalTabState>();
    final tabKey2 = GlobalKey<TerminalTabState>();

    final session1 = SshSessionInfo(
      sessionId: 'test1',
      host: 'localhost',
      port: 10001,
      username: 'user1',
      displayName: 'test1',
    );
    final session2 = SshSessionInfo(
      sessionId: 'test2',
      host: 'localhost',
      port: 10002,
      username: 'user2',
      displayName: 'test2',
    );

    final tabController =
        TabController(length: 2, vsync: const TestVSync());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabBarView(
            controller: tabController,
            children: [
              TerminalTab(
                key: tabKey1,
                session: session1,
                onDisconnected: () {},
                connectOnInit: false,
                fontSize: 14.0,
              ),
              TerminalTab(
                key: tabKey2,
                session: session2,
                onDisconnected: () {},
                connectOnInit: false,
                fontSize: 14.0,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Both tabs start at 14
    expect(_terminalFontSize(tester), 14.0);

    // Pinch to zoom in on tab 1
    await _pinch(tester, find.byType(TerminalView), scale: 1.5);
    final tab1Size = _terminalFontSize(tester);
    expect(tab1Size, greaterThan(14.0));

    // Switch to tab 2
    tabController.animateTo(1);
    await tester.pumpAndSettle();

    // Tab 2 should still be at the default 14
    expect(_terminalFontSize(tester), 14.0);

    // Switch back to tab 1 — should retain zoomed size
    tabController.animateTo(0);
    await tester.pumpAndSettle();

    expect(_terminalFontSize(tester), tab1Size);

    tabController.dispose();
  });

  testWidgets('settings font size change resets tab font size',
      (tester) async {
    final tabKey = GlobalKey<TerminalTabState>();

    final session = SshSessionInfo(
      sessionId: 'test1',
      host: 'localhost',
      port: 10001,
      username: 'user1',
      displayName: 'test1',
    );

    Widget buildApp({required double fontSize}) {
      return MaterialApp(
        home: Scaffold(
          body: TerminalTab(
            key: tabKey,
            session: session,
            onDisconnected: () {},
            connectOnInit: false,
            fontSize: fontSize,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildApp(fontSize: 14.0));
    await tester.pumpAndSettle();

    // Pinch to change font size
    await _pinch(tester, find.byType(TerminalView), scale: 1.5);
    expect(_terminalFontSize(tester), greaterThan(14.0));

    // Simulate settings change — rebuild with new fontSize
    await tester.pumpWidget(buildApp(fontSize: 18.0));
    await tester.pumpAndSettle();

    expect(_terminalFontSize(tester), 18.0);
  });

  testWidgets('pinch-to-zoom unfocuses terminal to prevent keyboard opening',
      (tester) async {
    final terminal = Terminal(maxLines: 100);
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: TerminalPane(
              terminal: terminal,
              fontSize: 14.0,
              focusNode: focusNode,
              autofocus: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Terminal should have focus initially (autofocus)
    expect(focusNode.hasFocus, isTrue);

    // Perform a pinch gesture — during scaling the focus node should be
    // unfocused to prevent the keyboard from appearing.
    final center = tester.getCenter(find.byType(TerminalView));
    final offset = const Offset(50, 0);
    final start1 = center - offset;
    final start2 = center + offset;
    final end1 = center - offset * 1.5;
    final end2 = center + offset * 1.5;

    final gesture1 = await tester.startGesture(start1);
    await tester.pump();
    final gesture2 = await tester.startGesture(start2);
    await tester.pump();

    // After second pointer arrives, focus should be lost immediately
    expect(focusNode.hasFocus, isFalse,
        reason: 'Terminal should lose focus when second pointer arrives');

    // Move fingers apart to scale
    for (var i = 1; i <= 10; i++) {
      final t = i / 20;
      await gesture1.moveTo(Offset.lerp(start1, end1, t)!);
      await gesture2.moveTo(Offset.lerp(start2, end2, t)!);
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Focus should still be lost during the pinch gesture
    expect(focusNode.hasFocus, isFalse,
        reason: 'Terminal should remain unfocused during pinch');

    // Complete the gesture
    for (var i = 11; i <= 20; i++) {
      final t = i / 20;
      await gesture1.moveTo(Offset.lerp(start1, end1, t)!);
      await gesture2.moveTo(Offset.lerp(start2, end2, t)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture1.up();
    await gesture2.up();
    await tester.pump();

    focusNode.dispose();
  });
}
