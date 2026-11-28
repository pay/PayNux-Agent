import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import '../constants.dart';
import '../models/setup_state.dart';
import 'native_bridge.dart';

/// Marker files under <filesDir>/setup_state so a failed or interrupted setup
/// resumes at the failed step instead of starting over.
class _Checkpoints {
  _Checkpoints(String filesDir) : dir = Directory('$filesDir/setup_state');

  final Directory dir;

  static const rootfs = 'rootfs';
  static const packages = 'packages';
  static const hermesClone = 'hermes_clone';
  static const hermesDeps = 'hermes_deps';
  static const _all = [rootfs, packages, hermesClone, hermesDeps];

  File _f(String name) => File('${dir.path}/$name');

  bool has(String name) => _f(name).existsSync();

  Future<void> mark(String name) async {
    await dir.create(recursive: true);
    await _f(name).writeAsString(DateTime.now().toIso8601String());
  }

  /// Forget every step (used when the rootfs has to be rebuilt).
  Future<void> clearSteps() async {
    for (final n in _all) {
      final f = _f(n);
      if (f.existsSync()) await f.delete();
    }
  }

  /// While present, the native side reports the bootstrap as NOT complete.
  Future<void> markIncomplete() async {
    await dir.create(recursive: true);
    await _f('incomplete').writeAsString('1');
  }

  Future<void> markComplete() async {
    final f = _f('incomplete');
    if (f.existsSync()) await f.delete();
  }
}

class BootstrapService {
  final Dio _dio = Dio();

  void _updateSetupNotification(String text, {int progress = -1}) {
    try {
      NativeBridge.updateSetupNotification(text, progress: progress);
    } catch (_) {}
  }

  void _stopSetupService() {
    try {
      NativeBridge.stopSetupService();
    } catch (_) {}
  }

  Future<SetupState> checkStatus() async {
    try {
      final complete = await NativeBridge.isBootstrapComplete();
      if (complete) {
        return const SetupState(
          step: SetupStep.complete,
          progress: 1.0,
          message: 'Setup complete',
        );
      }
      return const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: 'Setup required',
      );
    } catch (e) {
      return SetupState(
        step: SetupStep.error,
        error: 'Failed to check status: $e',
      );
    }
  }

  /// Repair CUA runtime libraries on an already-bootstrapped rootfs.
  /// Uses the existing PRoot command path; never patches the driver binary.
  Future<void> ensureRuntimeDependencies({bool hermesChecks = true}) async {
    // Fast path: once verified, skip the 3-4 PRoot launches on every terminal
    // open. Kept outside setup_state/ on purpose (see isBootstrapComplete).
    final filesDir = await NativeBridge.getFilesDir();
    final doneMarker = File('$filesDir/runtime_deps_ok');
    if (hermesChecks == false && doneMarker.existsSync()) return;

    await NativeBridge.runInProot(
      r'if [ ! -f /root/.paynux_cua_deps_v1 ]; then '
      r'apt-get update -y && '
      r'apt-get install -y --no-install-recommends libx11-6 libxi6 libxkbcommon0 && '
      r'ldconfig && touch /root/.paynux_cua_deps_v1; fi',
      timeout: 900,
    );
    await NativeBridge.runInProot(
      "ldconfig -p | grep -q 'libX11.so.6' && "
      "ldconfig -p | grep -q 'libXi.so.6' && "
      "ldconfig -p | grep -q 'libxkbcommon.so.0'",
      timeout: 120,
    );
    if (hermesChecks) {
      // Hermes CLI is optional for opening a terminal. Only run PM checks
      // when the active rootfs actually provides the executable; otherwise
      // a missing `hermes` exits 127 and aborts shell startup.
      await NativeBridge.runInProot(
        r'export PATH="$HOME/.hermes/bin:$PATH"; '
        r'if command -v hermes >/dev/null 2>&1 || [ -x /root/.hermes/bin/hermes ]; then '
        r'cd /root/hermes-agent && hermes pm doctor && hermes pm install cua-driver; '
        r'else echo "hermes CLI not installed; skipping PM verification"; fi',
        timeout: 900,
      );
    }
    await NativeBridge.runInProot(
      r'DRV=$(command -v cua-driver || true); '
      r'[ -n "$DRV" ] || exit 0; '
      r'ldd "$DRV" | grep -q "not found" && exit 1 || exit 0',
      timeout: 120,
    );
    try {
      await doneMarker.writeAsString('1');
    } catch (_) {}
  }

  /// Streamed download with HTTP Range resume. A partial file from an earlier
  /// attempt is continued instead of re-downloaded.
  Future<void> _downloadWithResume(
    String url,
    String path,
    void Function(int received, int total) onProgress,
  ) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    for (var attempt = 0; attempt < 2; attempt++) {
      final start = file.existsSync() ? file.lengthSync() : 0;
      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: start > 0 ? {'range': 'bytes=$start-'} : null,
          validateStatus: (s) => s == 200 || s == 206 || s == 416,
        ),
      );
      final status = resp.statusCode;

      if (status == 416) {
        // Range not satisfiable: either the file is already complete or the
        // partial file is stale.
        await resp.data!.stream.drain<void>();
        final total = _totalFromContentRange(resp.headers.value('content-range'));
        if (total != null && total == start) return;
        if (file.existsSync()) await file.delete();
        continue;
      }

      final resumed = status == 206;
      final int? expected = resumed
          ? _totalFromContentRange(resp.headers.value('content-range'))
          : int.tryParse(resp.headers.value('content-length') ?? '');
      final base = resumed ? start : 0;

      final sink = file.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      var received = 0;
      try {
        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(base + received, expected ?? 0);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (expected != null && file.lengthSync() != expected) {
        throw Exception(
          'Download incomplete (${file.lengthSync()} / $expected bytes). Run setup again to resume.',
        );
      }
      return;
    }
    throw Exception('Could not resume download; please run setup again.');
  }

  int? _totalFromContentRange(String? header) {
    if (header == null) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(header.substring(slash + 1).trim());
  }

  /// Optional extra, never blocks or fails setup.
  Future<void> _installOptionalCuaDriver() async {
    try {
      await NativeBridge.runInProot(
        r'export PATH="$HOME/.hermes/bin:$PATH"; '
        r'if command -v hermes >/dev/null 2>&1 || [ -x /root/.hermes/bin/hermes ]; then '
        r'cd /root/hermes-agent && hermes pm install cua-driver || true; fi',
        timeout: 600,
      );
    } catch (_) {}
  }

  Future<void> runFullSetup({
    required void Function(SetupState) onProgress,
  }) async {
    try {
      try {
        await NativeBridge.startSetupService();
      } catch (_) {}

      onProgress(const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: 'Setting up directories...',
      ));
      _updateSetupNotification('Setting up directories...', progress: 2);
      try { await NativeBridge.setupDirs(); } catch (_) {}
      // Mandatory DNS setup before any PRoot-based bootstrap step.
      await NativeBridge.ensureDnsConfig();

      final arch = await NativeBridge.getArch();
      final rootfsUrl = AppConstants.getRootfsUrl(arch);
      final filesDir = await NativeBridge.getFilesDir();
      final cp = _Checkpoints(filesDir);
      await cp.markIncomplete();

      final tarPath = '$filesDir/tmp/ubuntu-rootfs.tar.gz';
      final bashPath = '$filesDir/rootfs/ubuntu/bin/bash';

      // ---- 1. Rootfs (download + extract) --------------------------------
      final rootfsReusable = cp.has(_Checkpoints.rootfs) && File(bashPath).existsSync();
      if (rootfsReusable) {
        onProgress(const SetupState(
          step: SetupStep.extractingRootfs,
          progress: 1.0,
          message: 'Rootfs already installed, skipping download',
        ));
      } else {
        // A rebuilt rootfs invalidates every later step.
        await cp.clearSteps();

        _updateSetupNotification('Downloading Ubuntu rootfs...', progress: 5);
        onProgress(const SetupState(
          step: SetupStep.downloadingRootfs,
          progress: 0.0,
          message: 'Downloading Ubuntu rootfs...',
        ));
        await _downloadWithResume(rootfsUrl, tarPath, (received, total) {
          if (total > 0) {
            final progress = received / total;
            final mb = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
            final notifProgress = 5 + (progress * 25).round();
            _updateSetupNotification('Downloading rootfs: $mb / $totalMb MB',
                progress: notifProgress);
            onProgress(SetupState(
              step: SetupStep.downloadingRootfs,
              progress: progress,
              message: 'Downloading: $mb MB / $totalMb MB',
            ));
          }
        });

        _updateSetupNotification('Extracting rootfs...', progress: 30);
        onProgress(const SetupState(
          step: SetupStep.extractingRootfs,
          progress: 0.0,
          message: 'Extracting rootfs (this takes a while)...',
        ));
        try {
          await NativeBridge.extractRootfs(tarPath);
        } catch (e) {
          // A corrupt archive must not be "resumed" forever: drop it so the
          // next attempt downloads a fresh copy.
          try {
            final t = File(tarPath);
            if (t.existsSync()) await t.delete();
          } catch (_) {}
          rethrow;
        }
        await cp.mark(_Checkpoints.rootfs);
        onProgress(const SetupState(
          step: SetupStep.extractingRootfs,
          progress: 1.0,
          message: 'Rootfs extracted',
        ));
      }

      // ---- 2. Base packages -----------------------------------------------
      // Permissions are now applied during extraction, so the separate
      // `chmod -R` PRoot pass is gone; only the dpkg dirs are still needed.
      if (cp.has(_Checkpoints.packages)) {
        onProgress(const SetupState(
          step: SetupStep.installingPython,
          progress: 1.0,
          message: 'Base packages already installed',
        ));
      } else {
        _updateSetupNotification('Updating package lists...', progress: 48);
        onProgress(const SetupState(
          step: SetupStep.installingPython,
          progress: 0.1,
          message: 'Updating package lists...',
        ));
        await NativeBridge.runInProot(
          'mkdir -p /var/lib/dpkg/updates /var/lib/dpkg/triggers && '
          'apt-get update -y',
        );

        _updateSetupNotification('Installing base packages...', progress: 52);
        onProgress(const SetupState(
          step: SetupStep.installingPython,
          progress: 0.15,
          message: 'Installing base packages...',
        ));
        await NativeBridge.runInProot(
          'ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && '
          'echo "Etc/UTC" > /etc/timezone',
        );
        // cua-driver links against X11 client libraries; ubuntu-base does not
        // ship them. Installing them here keeps the fix in the PRoot setup path
        // without touching or patching the driver binary.
        await NativeBridge.runInProot(
          'apt-get install -y --no-install-recommends '
          'ca-certificates git python3 python3-venv python3-pip curl wget '
          'libx11-6 libxi6 libxkbcommon0',
        );
        _updateSetupNotification('Verifying CUA runtime libraries...', progress: 56);
        await NativeBridge.runInProot(
          "ldconfig -p | grep -q 'libX11.so.6' && "
          "ldconfig -p | grep -q 'libXi.so.6' && "
          "ldconfig -p | grep -q 'libxkbcommon.so.0' && "
          'touch /root/.paynux_cua_deps_v1',
          timeout: 120,
        );
        await cp.mark(_Checkpoints.packages);
      }

      // ---- 3. Hermes clone ------------------------------------------------
      final runPy = File('$filesDir/rootfs/ubuntu/root/hermes-agent/gateway/run.py');
      if (cp.has(_Checkpoints.hermesClone) && runPy.existsSync()) {
        onProgress(const SetupState(
          step: SetupStep.installingHermesAgent,
          progress: 0.5,
          message: 'Hermes Agent already cloned',
        ));
      } else {
        _updateSetupNotification('Cloning Hermes Agent...', progress: 70);
        onProgress(const SetupState(
          step: SetupStep.installingHermesAgent,
          progress: 0.0,
          message: 'Cloning Hermes Agent repository...',
        ));
        await NativeBridge.runInProot(
          'cd /root && '
          'rm -rf hermes-agent.clone.tmp && '
          'GIT_TERMINAL_PROMPT=0 git clone --depth 1 --progress '
          'https://github.com/nousresearch/hermes-agent.git hermes-agent.clone.tmp && '
          'if [ -d hermes-agent ]; then mv hermes-agent hermes-agent.previous; fi && '
          'if mv hermes-agent.clone.tmp hermes-agent; then '
          'rm -rf hermes-agent.previous; '
          'else [ ! -d hermes-agent.previous ] || mv hermes-agent.previous hermes-agent; exit 1; fi',
          timeout: 600,
        );
        // A fresh clone means dependencies must be (re)installed.
        final deps = File('${cp.dir.path}/${_Checkpoints.hermesDeps}');
        if (deps.existsSync()) await deps.delete();
        await cp.mark(_Checkpoints.hermesClone);
      }

      // ---- 4. Python dependencies -----------------------------------------
      if (cp.has(_Checkpoints.hermesDeps)) {
        onProgress(const SetupState(
          step: SetupStep.installingHermesAgent,
          progress: 0.9,
          message: 'Python dependencies already installed',
        ));
      } else {
        _updateSetupNotification('Installing Python dependencies...', progress: 85);
        onProgress(const SetupState(
          step: SetupStep.installingHermesAgent,
          progress: 0.5,
          message: 'Installing Python dependencies...',
        ));
        await NativeBridge.runInProot(
          'cd /root/hermes-agent && '
          'grep -q UV_LINK_MODE pm/index_config.py || '
          'sed -i \'/FORWARDED_UV_SETTINGS[[:space:]]*=/a\\    "UV_LINK_MODE",\' pm/index_config.py && '
          'UV_LINK_MODE=copy ./setup-hermes.sh --runtime-only',
          timeout: 1800,
        );
        await cp.mark(_Checkpoints.hermesDeps);
      }

      _updateSetupNotification('Verifying installation...', progress: 96);
      onProgress(const SetupState(
        step: SetupStep.installingHermesAgent,
        progress: 0.95,
        message: 'Verifying Hermes Agent installation...',
      ));
      await NativeBridge.runInProot(
        'test -f /root/hermes-agent/gateway/run.py && echo hermes_ready',
      );
      onProgress(const SetupState(
        step: SetupStep.installingHermesAgent,
        progress: 1.0,
        message: 'Hermes Agent installed',
      ));

      // Mark finished BEFORE the optional extras so a slow/failed extra can
      // never leave the app stuck in "setup required".
      try {
        await File('$filesDir/runtime_deps_ok').writeAsString('1');
      } catch (_) {}
      await cp.markComplete();

      _updateSetupNotification('Setup complete!', progress: 100);
      onProgress(const SetupState(
        step: SetupStep.configuringEnvironment,
        progress: 1.0,
        message: 'Environment configured',
      ));

      _stopSetupService();
      onProgress(const SetupState(
        step: SetupStep.complete,
        progress: 1.0,
        message: 'Setup complete! Ready to start the agent.',
      ));

      // cua-driver is an optional extra: install it in the background,
      // best-effort, instead of blocking setup for up to 15 minutes.
      unawaited(_installOptionalCuaDriver());
    } on DioException catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Download failed: ${e.message}. Run setup again to resume.',
      ));
    } catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Setup failed: $e. Run setup again to resume from this step.',
      ));
    }
  }
}
