import 'dart:async';
import 'package:flutter/foundation.dart';
import '../constants.dart';
import '../models/gateway_state.dart';
import 'native_bridge.dart';
import 'preferences_service.dart';

class GatewayService {
  Timer? _healthTimer;
  Timer? _initialDelayTimer;
  StreamSubscription? _logSubscription;
  final _stateController = StreamController<GatewayState>.broadcast();
  GatewayState _state = const GatewayState();
  DateTime? _startingAt;
  bool _startInProgress = false;
  bool _stopInProgress = false;
  bool _restartInProgress = false;
  int _operationGeneration = 0;

  static String _ts(String msg) => '${DateTime.now().toUtc().toIso8601String()} $msg';

  Stream<GatewayState> get stateStream => _stateController.stream;
  GatewayState get state => _state;

  void _updateState(GatewayState newState) {
    _state = newState;
    // Late async work (init/health checks) may finish after dispose.
    if (_stateController.isClosed) return;
    _stateController.add(_state);
  }

  Future<void> init() async {
    final prefs = PreferencesService();
    await prefs.init();

    try { await NativeBridge.setupDirs(); } catch (_) {}
    try {
      await NativeBridge.ensureDnsConfig();
    } catch (e) {
      debugPrint('[DNS] init setup failed: $e');
    }

    final alreadyRunning = await NativeBridge.isGatewayRunning();
    if (alreadyRunning) {
      _startingAt = DateTime.now();
      _updateState(_state.copyWith(
        status: GatewayStatus.starting,
        logs: [..._state.logs, _ts('[INFO] Gateway process detected, reconnecting...')],
      ));
      _subscribeLogs();
      _startHealthCheck();
    } else if (prefs.autoStartGateway) {
      _updateState(_state.copyWith(
        logs: [..._state.logs, _ts('[INFO] Auto-starting gateway...')],
      ));
      await start();
    }
  }

  void _subscribeLogs() {
    _logSubscription?.cancel();
    _logSubscription = NativeBridge.gatewayLogStream.listen((log) {
      final logs = [..._state.logs, log];
      if (logs.length > 500) {
        logs.removeRange(0, logs.length - 500);
      }
      _updateState(_state.copyWith(logs: logs));
    });
  }

  Future<void> start() async {
    if (_startInProgress) return;
    final generation = ++_operationGeneration;
    _startInProgress = true;

    _updateState(_state.copyWith(
      status: GatewayStatus.starting,
      clearError: true,
      logs: [..._state.logs, _ts('[INFO] Starting gateway...')],
    ));

    try {
      try { await NativeBridge.setupDirs(); } catch (_) {}
      // Mandatory: abort start if DNS config cannot be prepared.
      await NativeBridge.ensureDnsConfig();
      // Register the app's real GIDs on the active rootfs before PRoot starts.
      await NativeBridge.prepareProotEnvironment();
      if (generation != _operationGeneration) return;

      _startingAt = DateTime.now();
      await NativeBridge.startGateway();
      _subscribeLogs();
      _startHealthCheck();
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to start: $e',
        logs: [..._state.logs, _ts('[ERROR] Failed to start: $e')],
      ));
    } finally {
      // Always release our own flag. Guarding on the generation left the flag
      // stuck forever when a newer operation superseded this one, and every
      // later tap was then silently ignored by the early return above.
      _startInProgress = false;
    }
  }

  /// Stops the gateway asynchronously. The native side replies only after the
  /// Python/PRoot processes are verified dead, so no hard-exit is needed and
  /// the UI stays alive throughout the operation.
  Future<void> stop() async {
    if (_stopInProgress) return;
    final generation = ++_operationGeneration;
    _stopInProgress = true;
    _cancelAllTimers();
    await _logSubscription?.cancel();
    _logSubscription = null;
    _startingAt = null;

    try {
      final stopped = await NativeBridge.stopGateway();
      _updateState(GatewayState(
        status: GatewayStatus.stopped,
        logs: [
          ..._state.logs,
          if (stopped)
            _ts('[INFO] Gateway stopped')
          else
            _ts('[WARN] Gateway stop completed with warnings - verify processes'),
        ],
      ));
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to stop: $e',
      ));
    } finally {
      _stopInProgress = false;
    }
  }

  /// Restarts the gateway: controlled stop, verified cleanup, then relaunch.
  /// Never terminates the app process.
  Future<void> restart() async {
    if (_restartInProgress) return;
    final generation = ++_operationGeneration;
    _restartInProgress = true;
    _cancelAllTimers();
    await _logSubscription?.cancel();
    _logSubscription = null;
    _startingAt = null;

    _updateState(_state.copyWith(
      status: GatewayStatus.starting,
      clearError: true,
      clearDashboardUrl: true,
      logs: [..._state.logs, _ts('[INFO] Restarting gateway...')],
    ));

    try {
      // Re-attach to the log stream BEFORE the native restart so the stop /
      // relaunch logs are visible while it runs.
      _subscribeLogs();
      final restarted = await NativeBridge.restartGateway();
      // A Stop that arrived while native restart was in flight wins: do not
      // re-arm health checks or overwrite the stopped state.
      if (generation != _operationGeneration) return;
      if (!restarted) {
        // Verification can fail even though the new process is fine. Never
        // kill a healthy gateway just because it was not confirmed.
        final alive = await NativeBridge.isGatewayRunning();
        if (generation != _operationGeneration) return;
        if (alive) {
          _updateState(_state.copyWith(
            logs: [
              ..._state.logs,
              _ts('[WARN] Restart not fully verified, but gateway process is alive'),
            ],
          ));
          _startHealthCheck();
          _startingAt = DateTime.now();
          return;
        }
        _updateState(_state.copyWith(
          logs: [
            ..._state.logs,
            _ts('[WARN] Native restart not confirmed, falling back to stop+start'),
          ],
        ));
        try { await NativeBridge.stopGateway(); } catch (_) {}
        if (generation != _operationGeneration) return;
        // start() bumps the generation, so release the flag first.
        _restartInProgress = false;
        await start();
        return;
      }
      _startHealthCheck();
      _startingAt = DateTime.now();
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to restart: $e',
        logs: [..._state.logs, _ts('[ERROR] Failed to restart: $e')],
      ));
    } finally {
      _restartInProgress = false;
    }
  }

  void _cancelAllTimers() {
    _initialDelayTimer?.cancel();
    _initialDelayTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  void _startHealthCheck() {
    _cancelAllTimers();
    _initialDelayTimer = Timer(const Duration(seconds: 30), () {
      _initialDelayTimer = null;
      if (_state.status == GatewayStatus.stopped) return;
      _checkHealth();
      _healthTimer = Timer.periodic(
        const Duration(milliseconds: AppConstants.healthCheckIntervalMs),
        (_) => _checkHealth(),
      );
    });
  }

  Future<void> _checkHealth() async {
    try {
      final isRunning = await NativeBridge.isGatewayRunning();
      if (isRunning && _state.status != GatewayStatus.running) {
        _updateState(_state.copyWith(
          status: GatewayStatus.running,
          startedAt: DateTime.now(),
          logs: [..._state.logs, _ts('[INFO] Gateway is running')],
        ));
      } else if (!isRunning && _state.status != GatewayStatus.stopped) {
        if (_startingAt != null &&
            _state.status == GatewayStatus.starting &&
            DateTime.now().difference(_startingAt!).inSeconds < 120) {
          _updateState(_state.copyWith(
            logs: [..._state.logs, _ts('[INFO] Starting, waiting for gateway...')],
          ));
          return;
        }
        _updateState(_state.copyWith(
          status: GatewayStatus.stopped,
          logs: [..._state.logs, _ts('[WARN] Gateway process not running')],
        ));
        _cancelAllTimers();
      }
    } catch (_) {
      final isRunning = await NativeBridge.isGatewayRunning();
      if (!isRunning && _state.status != GatewayStatus.stopped) {
        if (_startingAt != null &&
            _state.status == GatewayStatus.starting &&
            DateTime.now().difference(_startingAt!).inSeconds < 120) {
          _updateState(_state.copyWith(
            logs: [..._state.logs, _ts('[INFO] Starting, waiting for gateway...')],
          ));
          return;
        }
        _updateState(_state.copyWith(
          status: GatewayStatus.stopped,
          logs: [..._state.logs, _ts('[WARN] Gateway process not running')],
        ));
        _cancelAllTimers();
      }
    }
  }

  Future<bool> checkHealth() async {
    return NativeBridge.isGatewayRunning();
  }

  void dispose() {
    _cancelAllTimers();
    _logSubscription?.cancel();
    _stateController.close();
  }
}
