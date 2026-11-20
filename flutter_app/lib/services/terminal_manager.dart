import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'native_bridge.dart';
import 'terminal_service.dart';

/// Outcome of a terminal shutdown. "exited" means both the PTY process and
/// its native-verified process tree are gone. Native /proc scanning is
/// performed by TerminalProcessController, not by this Dart file.
enum TerminalShutdownState {
  exited,
  timeout,
  unknown,
  /// Native could not verify the PRoot/Bash/Python tree is gone.
  treeUnverified,
}

/// Never interprets a timeout as success. Returns null on timeout/error so
/// callers can fail closed and keep registration data for retry.
Future<T?> callWithTimeout<T>(
  Future<T> future, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    return await future.timeout(timeout);
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  }
}

class TerminalSession {
  TerminalSession(this.id) : terminal = Terminal(maxLines: 10000);

  final int id;
  final Terminal terminal;
  final ValueNotifier<bool> ctrlNotifier = ValueNotifier(false);
  final ValueNotifier<bool> altNotifier = ValueNotifier(false);

  Pty? pty;
  // Test seam only: lets tests inject a fake process for shutdown sequencing.
  dynamic processOverride;
  bool loading = true;
  String? error;
  bool closing = false;
  bool starting = false;
  int startGeneration = 0;
  StreamSubscription<Uint8List>? outputSubscription;

  bool get isRunning => pty != null;

  void dispose() {
    outputSubscription?.cancel();
    outputSubscription = null;
    terminal.onOutput = null;
    terminal.onResize = null;
    ctrlNotifier.dispose();
    altNotifier.dispose();
  }
}

class TerminalManager extends ChangeNotifier {
  TerminalManager._() {
    final first = TerminalSession(_nextId++);
    sessions.add(first);
    activeSessionId = first.id;
    _listenForNativeShutdown();
  }

  StreamSubscription<dynamic>? _controlSubscription;
  bool controlChannelFailed = false;

  void _listenForNativeShutdown() {
    _controlSubscription = NativeBridge.terminalControlStream.listen(
      (event) async {
        if (event == 'close_all') {
          final verified = await closeAllSessions();
          try {
            await callWithTimeout(
              NativeBridge.notifyTerminalShutdownComplete(verified),
            );
          } catch (_) {
            // Native keeps its own timeout and unresolved state.
          }
        } else if (event == 'trees_terminated_by_native') {
          // Native already verified and unregistered the trees. Only sync UI.
          await closeAllSessions(nativeAlreadyTerminated: true);
        }
      },
      onError: (Object error) {
        controlChannelFailed = true;
        debugPrint('Terminal control channel error: $error');
        notifyListeners();
      },
      onDone: () {
        controlChannelFailed = true;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _controlSubscription?.cancel();
    super.dispose();
  }

  static final TerminalManager instance = TerminalManager._();

  final List<TerminalSession> sessions = [];
  int _nextId = 1;
  int activeSessionId = 0;

  TerminalSession get activeSession {
    for (final session in sessions) {
      if (session.id == activeSessionId) return session;
    }
    if (sessions.isNotEmpty) return sessions.first;
    // Native "close all" may leave zero sessions; keep the getter safe without
    // starting a new shell.
    final idle = TerminalSession(_nextId++);
    idle.loading = false;
    sessions.add(idle);
    activeSessionId = idle.id;
    return idle;
  }

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

  /// Sequential shutdown: SIGTERM -> bounded wait -> SIGKILL -> bounded wait.
  /// Dynamic parameter keeps this testable with a fake process; in production
  /// it is a [Pty]. A PTY exit alone is NOT proof that PRoot children died.
  @visibleForTesting
  static Future<TerminalShutdownState> shutdownProcess(
    dynamic process, {
    int? sessionId,
    Duration firstWait = const Duration(seconds: 4),
    Duration secondWait = const Duration(seconds: 2),
    Duration channelTimeout = const Duration(seconds: 10),
  }) async {
    // Native owns process-tree verification. It signals the verified tree
    // first; Dart then waits for the PTY to report its own exit.
    if (sessionId != null) {
      try {
        final treeVerified = await callWithTimeout(
          NativeBridge.terminateTerminalTree(sessionId),
          timeout: channelTimeout,
        );
        if (treeVerified != true) return TerminalShutdownState.treeUnverified;
        try {
          await (process.exitCode as Future<int>).timeout(firstWait);
          return TerminalShutdownState.exited;
        } on TimeoutException {
          return TerminalShutdownState.timeout;
        } catch (_) {
          return TerminalShutdownState.unknown;
        }
      } catch (_) {
        return TerminalShutdownState.treeUnverified;
      }
    }

    try {
      if (process.kill(ProcessSignal.sigterm) != true) {
        return TerminalShutdownState.unknown;
      }
    } catch (_) {
      return TerminalShutdownState.unknown;
    }

    var timedOut = false;
    try {
      await (process.exitCode as Future<int>).timeout(
        firstWait,
        onTimeout: () {
          timedOut = true;
          return -1;
        },
      );
    } catch (_) {
      return TerminalShutdownState.unknown;
    }
    if (!timedOut) return TerminalShutdownState.exited;

    try {
      if (process.kill(ProcessSignal.sigkill) != true) {
        return TerminalShutdownState.unknown;
      }
    } catch (_) {
      return TerminalShutdownState.unknown;
    }
    try {
      await (process.exitCode as Future<int>).timeout(secondWait);
      return TerminalShutdownState.exited;
    } on TimeoutException {
      return TerminalShutdownState.timeout;
    } catch (_) {
      return TerminalShutdownState.unknown;
    }
  }

  Future<void> closeSession(int id) async {
    if (sessions.length <= 1) return;

    // sessionId is the identity; never rely on a captured list index because
    // two sessions may be closing concurrently.
    final session = sessions.firstWhere(
      (s) => s.id == id,
      orElse: () => throw StateError('session $id not found'),
    );
    if (session.closing) return;

    session.closing = true;
    session.startGeneration++;
    final process = session.processOverride ?? session.pty;
    session.pty = null;
    session.processOverride = null;

    TerminalShutdownState state = TerminalShutdownState.unknown;
    if (process != null) {
      state = await shutdownProcess(process, sessionId: id);
    }

    // Keep the root registered on any non-clean result so a later cleanup can
    // retry with the original fingerprint.
    if (state == TerminalShutdownState.exited) {
      await callWithTimeout(
        NativeBridge.unregisterTerminalRoot(id),
        timeout: const Duration(seconds: 5),
      );
    }

    session.outputSubscription?.cancel();
    session.outputSubscription = null;
    session.terminal.onOutput = null;
    session.terminal.onResize = null;
    sessions.removeWhere((s) => s.id == id);
    session.dispose();

    if (activeSessionId == id) {
      activeSessionId = sessions.isNotEmpty ? sessions.first.id : 0;
    }

    if (!sessions.any((s) => s.isRunning)) {
      await callWithTimeout(NativeBridge.stopTerminalService());
    }

    if (state != TerminalShutdownState.exited) {
      debugPrint(
        'Terminal session $id shutdown state: ${state.name}; '
        'root kept for retry cleanup',
      );
    }
    notifyListeners();
  }

  /// Retry a previously unverified tree using the retained root fingerprint.
  Future<bool> retryCleanup(int sessionId) async {
    final verified = await callWithTimeout(
      NativeBridge.terminateTerminalTree(sessionId),
    );
    if (verified != true) return false;
    final removed = await callWithTimeout(
      NativeBridge.unregisterTerminalRoot(sessionId),
      timeout: const Duration(seconds: 5),
    );
    return removed == true;
  }

  /// Used by the native ACTION_EXIT path. When native already verified the
  /// trees it also unregistered them, so Dart only synchronises UI state.
  Future<bool> closeAllSessions({bool nativeAlreadyTerminated = false}) async {
    var allExited = true;
    final ids = sessions.map((s) => s.id).toList();
    for (final id in ids) {
      final index = sessions.indexWhere((s) => s.id == id);
      if (index < 0) continue;
      final session = sessions[index];
      if (session.closing) continue;
      session.closing = true;
      session.startGeneration++;
      final process = session.processOverride ?? session.pty;
      session.pty = null;
      session.processOverride = null;
      var sessionClean = true;
      if (!nativeAlreadyTerminated && process != null) {
        final state = await shutdownProcess(process, sessionId: id);
        if (state != TerminalShutdownState.exited) {
          allExited = false;
          sessionClean = false;
        }
      }
      if (!nativeAlreadyTerminated && sessionClean) {
        await callWithTimeout(
          NativeBridge.unregisterTerminalRoot(id),
          timeout: const Duration(seconds: 5),
        );
      }
      session.outputSubscription?.cancel();
      session.outputSubscription = null;
      session.terminal.onOutput = null;
      session.terminal.onResize = null;
      sessions.removeAt(index);
      session.dispose();
    }
    activeSessionId = 0; // activeSession getter will create an idle session
    return allExited;
  }

  Future<void> startShell([TerminalSession? target]) async {
    final session = target ?? activeSession;
    if (session.pty != null || session.closing || session.starting) return;

    session.starting = true;
    final generation = ++session.startGeneration;
    session.loading = true;
    session.error = null;
    notifyListeners();

    try {
      try {
        await NativeBridge.setupDirs();
      } catch (_) {}

      try {
        await NativeBridge.writeResolv();
      } catch (e) {
        debugPrint('DNS setup warning (continuing): $e');
      }

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

      // flutter_pty returns the PID right after fork(), before execvp()
      // installs the proot cmdline. Native probe() polls for that identity;
      // retry the channel briefly so a transport hiccup is not fatal either.
      var probeOk = false;
      for (var attempt = 0; attempt < 3 && !probeOk; attempt++) {
        final result = await callWithTimeout(
          NativeBridge.probeTerminalPid(process.pid, timeoutMs: 600),
          timeout: const Duration(seconds: 3),
        );
        probeOk = result == true;
        if (!probeOk) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      if (!probeOk) {
        await _cleanupUnregisteredPty(process);
        session.error = 'PTY PID could not be verified before registration';
        session.loading = false;
        session.starting = false;
        notifyListeners();
        return;
      }

      final registered = await callWithTimeout(
        NativeBridge.registerTerminalRoot(session.id, process.pid),
      );
      if (registered != true) {
        await _cleanupUnregisteredPty(process);
        session.error = 'Failed to register terminal process tree';
        session.loading = false;
        session.starting = false;
        notifyListeners();
        return;
      }

      // If the session was closed or superseded while awaits were running,
      // shut the late process down instead of overwriting the old PTY ref.
      if (session.closing ||
          generation != session.startGeneration ||
          session.pty != null) {
        final lateState = await shutdownProcess(process, sessionId: session.id);
        if (lateState == TerminalShutdownState.exited) {
          await callWithTimeout(
            NativeBridge.unregisterTerminalRoot(session.id),
            timeout: const Duration(seconds: 5),
          );
        }
        session.starting = false;
        notifyListeners();
        return;
      }

      session.pty = process;
      session.outputSubscription = process.output.listen(
        (data) {
          if (identical(session.pty, process) && !session.closing) {
            terminal.write(utf8.decode(data, allowMalformed: true));
          }
        },
        onError: (Object _) {},
      );

      process.exitCode.then((code) async {
        if (!identical(session.pty, process)) return;

        session.pty = null;
        // Keep the root registration: descendant verification belongs to
        // native terminate/retry, not to the PTY exit event.
        await session.outputSubscription?.cancel();
        session.outputSubscription = null;
        if (!session.closing) {
          terminal.write('\r\n[Shell exited with code $code]\r\n');
        }

        if (!sessions.any((s) => s.isRunning)) {
          await NativeBridge.stopTerminalService();
        }
        notifyListeners();
      }).catchError((Object _) {});

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
      session.starting = false;
      notifyListeners();
    } catch (e) {
      session.pty = null;
      session.starting = false;
      session.loading = false;
      session.error = 'Failed to start shell: $e';

      if (!sessions.any((s) => s.isRunning)) {
        await NativeBridge.stopTerminalService();
      }
      notifyListeners();
    }
  }

  /// A PTY created before probe/register failed must never be left running.
  Future<void> _cleanupUnregisteredPty(dynamic process) async {
    try {
      await shutdownProcess(process);
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
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
