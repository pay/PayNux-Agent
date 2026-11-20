import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_agent_mobile/screens/terminal_screen.dart';

/// Verifies the terminal AppBar never accumulates more fixed width than the
/// screen provides at common phone widths. The status slot is Expanded +
/// ellipsis (and hidden entirely below 360), so it cannot force an overflow.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const widths = <double>[320, 360, 390, 430];

  for (final width in widths) {
    test('header fixed widths fit at ${width.toInt()}dp', () {
      final m = TerminalHeaderMetrics.of(width);
      expect(m.fixedWidth(), lessThanOrEqualTo(width),
          reason: 'fixed header elements must fit within $width dp');
    });
  }

  testWidgets('rendered header replica has no RenderFlex overflow',
      (tester) async {
    for (final width in widths) {
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final m = TerminalHeaderMetrics.of(width);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            toolbarHeight: 56,
            titleSpacing: m.isNarrow ? 2 : 4,
            leading: SizedBox(
              width: m.leadingWidth,
              child: IconButton(
                constraints:
                    BoxConstraints.tightFor(width: m.leadingWidth, height: 40),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.arrow_back, size: m.actionIconSize),
                onPressed: () {},
              ),
            ),
            title: Row(
              children: [
                Container(
                  width: m.badgeSize,
                  height: m.badgeSize,
                  decoration: const BoxDecoration(color: Color(0xFF151B23)),
                ),
                SizedBox(width: m.isNarrow ? 4 : 8),
                Expanded(
                  child: m.showStatus
                      ? const Text(
                          'UBUNTU  •  CONNECTED',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            actions: [
              for (var i = 0; i < 6; i++)
                SizedBox(
                  width: m.actionWidth,
                  child: IconButton(
                    constraints:
                        BoxConstraints.tightFor(width: m.actionWidth, height: 40),
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.copy, size: m.actionIconSize),
                    onPressed: () {},
                  ),
                ),
              SizedBox(
                width: m.actionWidth,
                child: IconButton(
                  constraints:
                      BoxConstraints.tightFor(width: m.actionWidth, height: 40),
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert, size: m.actionIconSize),
                  onPressed: () {},
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'no overflow exception at ${width.toInt()}dp');
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
