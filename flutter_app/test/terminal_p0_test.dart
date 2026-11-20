import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_agent_mobile/constants.dart';
import 'package:hermes_agent_mobile/services/native_bridge.dart';
import 'package:hermes_agent_mobile/services/terminal_manager.dart';

class FakeProcess {
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> kills = [];
  bool failKill = false;
  bool completeOnKill = true;

  Future<int> get exitCode => _exit.future;

  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills.add(signal);
    if (failKill) return false;
    if (completeOnKill && signal == ProcessSignal.sigkill && !_exit.isCompleted) {
      _exit.complete(-9);
    }
    return true;
  }

  void complete(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(AppConstants.channelName);
  const controlChannel =
      EventChannel(AppConstants.terminalControlEventChannelName);
  final calls = <String>[];
  final channelArgs = <String, Object?>{};

  Future<dynamic> defaultHandler(MethodCall call) async {
    calls.add(call.method);
    channelArgs[call.method] = call.arguments;
    switch (call.method) {
      case 'setupDirs':
      case 'writeResolv':
      case 'registerMissingAndroidGroups':
      case 'startTerminalService':
      case 'stopTerminalService':
      case 'notifyTerminalShutdownComplete':
      case 'probeTerminalPid':
      case 'registerTerminalRoot':
      case 'unregisterTerminalRoot':
      case 'terminateTerminalTree':
        return true;
      case 'getFilesDir':
      case 'getExternalStoragePath':
        return '/tmp';
      case 'hasStoragePermission':
        return false;
      default:
        return null;
    }
  }

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, defaultHandler);
    messenger.setMockStreamHandler(
      controlChannel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {},
        onCancel: (Object? arguments) {},
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(controlChannel, null);
    final manager = TerminalManager.instance;
    manager.sessions.clear();
    manager.activeSessionId = 0;
  });

  group('P0-3 shutdown sequencing', () {
    test('SIGTERM path reports exited', () async {
      final fake = FakeProcess()..complete(0);
      final state = await TerminalManager.shutdownProcess(
        fake,
        firstWait: const Duration(milliseconds: 50),
        secondWait: const Duration(milliseconds: 50),
      );
      expect(state, TerminalShutdownState.exited);
      expect(fake.kills, [ProcessSignal.sigterm]);
    });

    test('timeout escalates to SIGKILL and reports timeout', () async {
      final fake = FakeProcess()..completeOnKill = false;
      final state = await TerminalManager.shutdownProcess(
        fake,
        firstWait: const Duration(milliseconds: 50),
        secondWait: const Duration(milliseconds: 50),
      );
      expect(state, TerminalShutdownState.timeout);
      expect(fake.kills, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    });

    test('kill failure reports unknown', () async {
      final fake = FakeProcess()..failKill = true;
      final state = await TerminalManager.shutdownProcess(
        fake,
        firstWait: const Duration(milliseconds: 50),
        secondWait: const Duration(milliseconds: 50),
      );
      expect(state, TerminalShutdownState.unknown);
    });

    test('double close sends only one shutdown', () async {
      final manager = TerminalManager.instance;
      final first = TerminalSession(901);
      final fake = FakeProcess()..complete(0);
      first.processOverride = fake;
      manager.sessions.add(first);
      manager.sessions.add(TerminalSession(902));
      manager.activeSessionId = 901;

      await Future.wait([
        manager.closeSession(901),
        manager.closeSession(901),
      ]);

      // Native controller now owns signalling, including for multi-close.
      expect(fake.kills, isEmpty);
      expect(calls.where((c) => c == 'terminateTerminalTree').length, 1);
      expect(manager.sessions.any((s) => s.id == 901), isFalse);
      expect(manager.sessions.any((s) => s.id == 902), isTrue);
    });
  });

  group('P0-2 concurrent start', () {
    test('second start while first awaits is ignored', () async {
      final manager = TerminalManager.instance;
      final gate = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getFilesDir') return gate.future;
        return defaultHandler(call);
      });
      final session = TerminalSession(700);
      manager.sessions.add(session);
      manager.activeSessionId = 700;

      final first = manager.startShell(session);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(session.starting, isTrue);
      final generation = session.startGeneration;

      manager.startShell(session);
      expect(session.startGeneration, generation);

      gate.complete('/tmp');
      await first;
      expect(session.starting, isFalse);
    });

    test('close during start removes session and invalidates start', () async {
      final manager = TerminalManager.instance;
      final gate = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getFilesDir') return gate.future;
        return defaultHandler(call);
      });
      final session = TerminalSession(710);
      manager.sessions.add(session);
      manager.sessions.add(TerminalSession(711));
      manager.activeSessionId = 710;

      final first = manager.startShell(session);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final generation = session.startGeneration;
      final closing = manager.closeSession(710);

      expect(session.closing, isTrue);
      expect(session.startGeneration, greaterThan(generation));
      gate.complete('/tmp');
      await Future.wait([first, closing]);
      expect(manager.sessions.any((s) => s.id == 710), isFalse);
    });
  });

  group('native process tree integration', () {
    test('native verification precedes PTY exit result', () async {
      final fake = FakeProcess()..complete(0);
      final state = await TerminalManager.shutdownProcess(
        fake,
        sessionId: 42,
        firstWait: const Duration(milliseconds: 50),
        secondWait: const Duration(milliseconds: 50),
      );
      expect(state, TerminalShutdownState.exited);
      expect(calls, contains('terminateTerminalTree'));
      // Native owns signalling; Dart must not signal the PTY separately.
      expect(fake.kills, isEmpty);
    });

    test('unverified tree is a failure, not success', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'terminateTerminalTree') return false;
        return defaultHandler(call);
      });
      final fake = FakeProcess()..complete(0);
      final state = await TerminalManager.shutdownProcess(
        fake,
        sessionId: 43,
        firstWait: const Duration(milliseconds: 50),
      );
      expect(state, TerminalShutdownState.treeUnverified);
      expect(fake.kills, isEmpty);
    });
  });

  group('final P0 process-tree guards', () {
    test('channel timeout is never reported as success', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'terminateTerminalTree') {
          return Completer<bool>().future; // never completes
        }
        return defaultHandler(call);
      });
      final fake = FakeProcess()..complete(0);
      final state = await TerminalManager.shutdownProcess(
        fake,
        sessionId: 60,
        firstWait: const Duration(milliseconds: 20),
        channelTimeout: const Duration(milliseconds: 30),
      );
      expect(state, TerminalShutdownState.treeUnverified);
    });

    test('unregister is deferred when tree is unverified', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'terminateTerminalTree') return false;
        return defaultHandler(call);
      });
      final manager = TerminalManager.instance;
      final first = TerminalSession(70);
      first.processOverride = FakeProcess()..complete(0);
      manager.sessions.add(first);
      manager.sessions.add(TerminalSession(71));
      manager.activeSessionId = 70;

      await manager.closeSession(70);
      expect(calls, isNot(contains('unregisterTerminalRoot')));
      expect(manager.sessions.any((s) => s.id == 70), isFalse);
    });

    test('retry cleanup uses retained root and unregisters only when clean',
        () async {
      var attempt = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'terminateTerminalTree') {
          attempt++;
          return attempt > 1;
        }
        return defaultHandler(call);
      });
      final manager = TerminalManager.instance;
      // A previous attempt failed and kept the root registered.
      await NativeBridge.terminateTerminalTree(80);
      expect(await manager.retryCleanup(80), isTrue);
      expect(calls.where((c) => c == 'terminateTerminalTree').length, 2);
      expect(calls, contains('unregisterTerminalRoot'));
    });

    test('two sessions close concurrently without index mix-up', () async {
      final manager = TerminalManager.instance;
      final a = TerminalSession(90);
      final b = TerminalSession(91);
      final c = TerminalSession(92);
      a.processOverride = FakeProcess()..complete(0);
      c.processOverride = FakeProcess()..complete(0);
      manager.sessions.addAll([a, b, c]);
      manager.activeSessionId = 90;

      await Future.wait([
        manager.closeSession(90),
        manager.closeSession(92),
      ]);

      expect(manager.sessions.map((s) => s.id), [91]);
      expect(manager.activeSessionId, 91);
    });
  });

  test('probeTerminalPid forwards pid and bounded timeout', () async {
    await NativeBridge.probeTerminalPid(321, timeoutMs: 250);
    expect(channelArgs['probeTerminalPid'], {'pid': 321, 'timeoutMs': 250});
  });
}
