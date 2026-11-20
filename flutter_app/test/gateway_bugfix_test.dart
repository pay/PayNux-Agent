import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_agent_mobile/constants.dart';
import 'package:hermes_agent_mobile/models/gateway_state.dart';
import 'package:hermes_agent_mobile/providers/gateway_provider.dart';
import 'package:hermes_agent_mobile/services/gateway_service.dart' as svc;
import 'package:hermes_agent_mobile/services/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  const nativeChannel = MethodChannel(AppConstants.channelName);
  const logsChannel = EventChannel(AppConstants.eventChannelName);
  const prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(prefsChannel, (call) async {
      if (call.method == 'getAll') return <String, Object>{};
      return null;
    });
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'stopGateway':
        case 'restartGateway':
        case 'isGatewayRunning':
        case 'setupDirs':
        case 'prepareProotEnvironment':
        case 'writeResolv':
      case 'ensureDnsConfig':
        case 'shareText':
          return true;
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      logsChannel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {},
        onCancel: (Object? arguments) {},
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(prefsChannel, null);
    messenger.setMockStreamHandler(logsChannel, null);
  });

  test('GatewayService.stop waits for native verification and marks stopped',
      () async {
    final service = svc.GatewayService();
    await service.stop();

    expect(calls.where((c) => c.method == 'stopGateway').length, 1);
    expect(service.state.status, GatewayStatus.stopped);
    expect(service.state.logs.join('\n'), contains('[INFO] Gateway stopped'));
    service.dispose();
  });

  test('GatewayService.restart delegates to native restartGateway', () async {
    final service = svc.GatewayService();
    await service.restart();

    expect(calls.where((c) => c.method == 'restartGateway').length, 1);
    expect(service.state.status, GatewayStatus.starting);
    expect(service.state.logs.join('\n'), contains('Restarting gateway'));
    service.dispose();
  });

  test('GatewayProvider exposes restart()', () async {
    final provider = GatewayProvider();
    await provider.restart();
    expect(calls.where((c) => c.method == 'restartGateway').length, 1);
    // Let the constructor's init() async work settle before disposal.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    provider.dispose();
  });

  test('stop while restart is pending cancels restart and replies once', () async {
    final restartCompleter = Completer<bool>();
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'restartGateway':
          return restartCompleter.future;
        case 'stopGateway':
          return true;
        case 'isGatewayRunning':
          return false;
        case 'setupDirs':
        case 'ensureDnsConfig':
          return true;
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    final restarting = service.restart();
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    if (!restartCompleter.isCompleted) restartCompleter.complete(true);
    await restarting;

    expect(calls.where((c) => c.method == 'stopGateway').length, 1);
    expect(service.state.status, GatewayStatus.stopped);
    service.dispose();
  });

  test('restart does not report ready before native verification completes',
      () async {
    final restartCompleter = Completer<bool>();
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'restartGateway':
          return restartCompleter.future;
        case 'setupDirs':
        case 'ensureDnsConfig':
          return true;
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    final restarting = service.restart();
    await Future<void>.delayed(Duration.zero);

    expect(service.state.status, GatewayStatus.starting);
    expect(service.state.logs.join('\n'), isNot(contains('not confirmed by native')));

    restartCompleter.complete(false);
    await restarting;
    expect(service.state.logs.join('\n'), contains('not confirmed by native'));
    service.dispose();
  });

  test('DNS setup failure aborts start without launching gateway', () async {
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'setupDirs':
          return true;
        case 'ensureDnsConfig':
          throw PlatformException(code: 'DNS_FAILED', message: 'bad resolv');
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    await service.start();

    expect(calls.where((c) => c.method == 'startGateway'), isEmpty);
    expect(service.state.status, GatewayStatus.error);
    expect(service.state.errorMessage, contains('DNS_FAILED'));
    service.dispose();
  });

  test('startup exception after PRoot launch reports error state', () async {
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'setupDirs':
        case 'ensureDnsConfig':
        case 'prepareProotEnvironment':
          return true;
        case 'startGateway':
          throw PlatformException(
            code: 'PROOT_LAUNCH_FAILED',
            message: 'spawn failed',
          );
        case 'isGatewayRunning':
          return false;
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    await service.start();

    expect(calls.where((c) => c.method == 'startGateway').length, 1);
    expect(service.state.status, GatewayStatus.error);
    expect(service.state.errorMessage, contains('PROOT_LAUNCH_FAILED'));
    service.dispose();
  });

  test('DNS failure concurrent with stop calls native stop once', () async {
    final dnsCompleter = Completer<Object?>();
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'setupDirs':
          return true;
        case 'ensureDnsConfig':
          return dnsCompleter.future;
        case 'stopGateway':
        case 'startGateway':
          return true;
        case 'isGatewayRunning':
          return false;
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    final starting = service.start();
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    dnsCompleter.completeError(
      PlatformException(code: 'DNS_FAILED', message: 'bad resolv'),
    );
    await starting;

    expect(calls.where((c) => c.method == 'stopGateway').length, 1);
    expect(service.state.status, GatewayStatus.error);
    expect(service.state.errorMessage, contains('DNS_FAILED'));
    service.dispose();
  });

  test('restart failure is reported and does not mark gateway running',
      () async {
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'restartGateway':
          return false;
        case 'setupDirs':
        case 'ensureDnsConfig':
        case 'prepareProotEnvironment':
          return true;
        case 'isGatewayRunning':
          return false;
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    await service.restart();

    expect(calls.where((c) => c.method == 'restartGateway').length, 1);
    expect(service.state.logs.join('\n'), contains('not confirmed by native'));
    service.dispose();
  });

  test('stop during restart wins and does not re-arm restart state', () async {
    final restartCompleter = Completer<bool>();
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'restartGateway':
          return restartCompleter.future;
        case 'stopGateway':
          return true;
        case 'setupDirs':
        case 'ensureDnsConfig':
        case 'prepareProotEnvironment':
          return true;
        case 'isGatewayRunning':
          return false;
        default:
          return null;
      }
    });
    final service = svc.GatewayService();
    final restarting = service.restart();
    await Future<void>.delayed(Duration.zero);
    await service.stop();
    restartCompleter.complete(false);
    await restarting;

    expect(calls.where((c) => c.method == 'stopGateway').length, 1);
    expect(service.state.status, GatewayStatus.stopped);
    service.dispose();
  });

  test('shareText routes log text through the native share sheet', () async {
    final result = await NativeBridge.shareText('line one\nline two');
    expect(result, isTrue);
    final shareCall = calls.firstWhere((c) => c.method == 'shareText');
    expect(shareCall.arguments['text'], 'line one\nline two');
  });

}
