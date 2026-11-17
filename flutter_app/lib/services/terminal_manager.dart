import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'native_bridge.dart';
import 'terminal_service.dart';

class TerminalSession {
  TerminalSession(this.id) : terminal = Terminal(maxLines: 10000);

  final int id;
  final Terminal terminal;
  final ValueNotifier<bool> ctrlNotifier = ValueNotifier(false);
  final ValueNotifier<bool> altNotifier = ValueNotifier(false);

  Pty? pty;
  bool loading = true;
  String? error;
  bool closing = false;

  bool get isRunning => pty != null;

  void dispose() {
    ctrlNotifier.dispose();
    altNotifier.dispose();
  }
}

class TerminalManager extends ChangeNotifier {
  TerminalManager._() {
    final first = TerminalSession(_nextId++);
    sessions.add(first);
    activeSessionId = first.id;
  }

  static final TerminalManager instance = TerminalManager._();

  final List<TerminalSession> sessions = [];
  int _nextId = 1;
  int activeSessionId = 0;

  TerminalSession get activeSession =>
      sessions.firstWhere((s) => s.id == activeSessionId);

  // Compatibility getters for existing TerminalScreen code.
  Terminal get terminal => activeSession.terminal;
  Pty? get pty => activeSession.pty;
  ValueNotifier<bool> get ctrlNotifier => activeSession.ctrlNotifier;
  ValueNotifier<bool> get altNotifier => activeSession.altNotifier;
  bool get loading => activeSession.loading;
  String? get error => activeSession.error;
  bool get isRunning => activeSession.isRunning;

  TerminalSession createSession() {
    final session = TerminalSession(_nextId++);
    sessions.add(session);
    activeSessionId = session.id;
    notifyListeners();
    startShell(session);
    return session;
  }

  void selectSession(int id) {
    if (!sessions.any((s) => s.id == id)) return;
    activeSessionId = id;
    notifyListeners();
  }

  Future<void> closeSession(int id) async {
    if (sessions.length <= 1) return;

    final index = sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;

    final session = sessions[index];
    session.closing = true;
    final process = session.pty;
    session.pty = null;

    if (process != null) {
      process.kill(ProcessSignal.sigterm);
    }

    sessions.removeAt(index);
    session.dispose();

    if (activeSessionId == id) {
      activeSessionId = sessions[index > 0 ? index - 1 : 0].id;
    }

    if (!sessions.any((s) => s.isRunning)) {
      await NativeBridge.stopTerminalService();
    }

    notifyListeners();
  }

  Future<void> startShell([TerminalSession? target]) async {
    final session = target ?? activeSession;
    if (session.pty != null || session.closing) return;

    session.loading = true;
    session.error = null;
    notifyListeners();

    try {
      try {
        await NativeBridge.setupDirs();
      } catch (_) {}

      try {
        await NativeBridge.writeResolv();
      } catch (_) {}

      try {
        await NativeBridge.registerMissingAndroidGroups();
      } catch (e) {
        debugPrint('Android group registration skipped: $e');
      }

      try {
        final filesDir = await NativeBridge.getFilesDir();
        const resolvContent = 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n';

        final resolvFile = File('$filesDir/config/resolv.conf');
        if (!resolvFile.existsSync()) {
          Directory('$filesDir/config').createSync(recursive: true);
          resolvFile.writeAsStringSync(resolvContent);
        }

        final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
        if (!rootfsResolv.existsSync()) {
          rootfsResolv.parent.createSync(recursive: true);
          rootfsResolv.writeAsStringSync(resolvContent);
        }
      } catch (_) {}

      final config = await TerminalService.getProotShellConfig();

      // Root prompt styling only; do not alter PRoot or Gateway arguments.
      _configureRootPrompt(config['rootfsDir']!);

      final terminal = session.terminal;
      final args = TerminalService.buildProotArgs(
        config,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      final process = Pty.start(
        config['executable']!,
        arguments: args,
        environment: TerminalService.buildHostEnv(config),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );

      if (session.closing) {
        process.kill(ProcessSignal.sigterm);
        return;
      }

      session.pty = process;

      process.output.listen((data) {
        if (identical(session.pty, process) && !session.closing) {
          terminal.write(utf8.decode(data, allowMalformed: true));
        }
      });

      process.exitCode.then((code) async {
        if (!identical(session.pty, process)) return;

        session.pty = null;
        if (!session.closing) {
          terminal.write('\r\n[Shell exited with code $code]\r\n');
        }

        if (!sessions.any((s) => s.isRunning)) {
          await NativeBridge.stopTerminalService();
        }
        notifyListeners();
      });

      terminal.onOutput = (data) {
        if (!identical(session.pty, process) || session.closing) return;

        if (session.ctrlNotifier.value && data.length == 1) {
          final code = data.toLowerCase().codeUnitAt(0);
          if (code >= 97 && code <= 122) {
            process.write(Uint8List.fromList([code - 96]));
            session.ctrlNotifier.value = false;
            return;
          }
        }

        if (session.altNotifier.value && data.isNotEmpty) {
          process.write(utf8.encode('\x1b$data'));
          session.altNotifier.value = false;
          return;
        }

        process.write(utf8.encode(data));
      };

      terminal.onResize = (w, h, pw, ph) {
        if (identical(session.pty, process)) {
          process.resize(h, w);
        }
      };

      session.loading = false;
      notifyListeners();
    } catch (e) {
      session.pty = null;
      session.loading = false;
      session.error = 'Failed to start shell: $e';

      if (!sessions.any((s) => s.isRunning)) {
        await NativeBridge.stopTerminalService();
      }
      notifyListeners();
    }
  }

  void _configureRootPrompt(String rootfsDir) {
    try {
      final bashrc = File('$rootfsDir/root/.bashrc');
      bashrc.parent.createSync(recursive: true);

      const marker = '# PAYNUX_ROOT_PROMPT';
      final existing = bashrc.existsSync() ? bashrc.readAsStringSync() : '';
      if (existing.contains(marker)) return;

      const prompt = r"""
# PAYNUX_ROOT_PROMPT
if [ "$EUID" -eq 0 ]; then
  PS1='\[\e[1;31m\]\u@localhost\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi
""";

      bashrc.writeAsStringSync(
        '${existing.trimRight()}\n$prompt',
        flush: true,
      );
    } catch (e) {
      debugPrint('Root prompt styling skipped: $e');
    }
  }

  void writeInput(String text) {
    pty?.write(utf8.encode(text));
  }

  void clearTerminal() {
    terminal.write('\x1b[2J\x1b[H');
  }
}
