import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_agent_mobile/screens/terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('copy all returns null for an empty terminal', () {
    expect(copyAllTerminalText(Terminal()), isNull);
  });

  test('copy all returns the whole visible buffer without a selection', () {
    final terminal = Terminal();
    terminal.write('first line\r\nsecond line\r\n');

    final text = copyAllTerminalText(terminal);
    expect(text, isNotNull);
    expect(text, contains('first line'));
    expect(text, contains('second line'));
  });
}
