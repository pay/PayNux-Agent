import 'package:dio/dio.dart';
import '../constants.dart';
import '../models/setup_state.dart';
import 'native_bridge.dart';

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

      final tarPath = '$filesDir/tmp/ubuntu-rootfs.tar.gz';

      _updateSetupNotification('Downloading Ubuntu rootfs...', progress: 5);
      onProgress(const SetupState(
        step: SetupStep.downloadingRootfs,
        progress: 0.0,
        message: 'Downloading Ubuntu rootfs...',
      ));

      await _dio.download(
        rootfsUrl,
        tarPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            final mb = (received / 1024 / 1024).toStringAsFixed(1);
            final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
            final notifProgress = 5 + (progress * 25).round();
            _updateSetupNotification('Downloading rootfs: $mb / $totalMb MB', progress: notifProgress);
            onProgress(SetupState(
              step: SetupStep.downloadingRootfs,
              progress: progress,
              message: 'Downloading: $mb MB / $totalMb MB',
            ));
          }
        },
      );

      _updateSetupNotification('Extracting rootfs...', progress: 30);
      onProgress(const SetupState(
        step: SetupStep.extractingRootfs,
        progress: 0.0,
        message: 'Extracting rootfs (this takes a while)...',
      ));
      await NativeBridge.extractRootfs(tarPath);
      onProgress(const SetupState(
        step: SetupStep.extractingRootfs,
        progress: 1.0,
        message: 'Rootfs extracted',
      ));

      _updateSetupNotification('Fixing rootfs permissions...', progress: 45);
      onProgress(const SetupState(
        step: SetupStep.installingPython,
        progress: 0.0,
        message: 'Fixing rootfs permissions...',
      ));
      await NativeBridge.runInProot(
        'chmod -R 755 /usr/bin /usr/sbin /bin /sbin '
        '/usr/local/bin /usr/local/sbin 2>/dev/null; '
        'chmod -R +x /usr/lib/apt/ /usr/lib/dpkg/ /usr/libexec/ '
        '/var/lib/dpkg/info/ /usr/share/debconf/ 2>/dev/null; '
        'chmod 755 /lib/*/ld-linux-*.so* /usr/lib/*/ld-linux-*.so* 2>/dev/null; '
        'mkdir -p /var/lib/dpkg/updates /var/lib/dpkg/triggers; '
        'echo permissions_fixed',
      );

      _updateSetupNotification('Updating package lists...', progress: 48);
      onProgress(const SetupState(
        step: SetupStep.installingPython,
        progress: 0.1,
        message: 'Updating package lists...',
      ));
      await NativeBridge.runInProot('apt-get update -y');

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
        "ldconfig -p | grep -q 'libxkbcommon.so.0'",
        timeout: 120,
      );

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

      _updateSetupNotification('Verifying installation...', progress: 96);
      onProgress(const SetupState(
        step: SetupStep.installingHermesAgent,
        progress: 0.9,
        message: 'Verifying Hermes Agent installation...',
      ));
      await NativeBridge.runInProot(
        'test -f /root/hermes-agent/gateway/run.py && echo hermes_ready',
      );
      _updateSetupNotification('Verifying Hermes PM...', progress: 97);
      await NativeBridge.runInProot(
        r'export PATH="$HOME/.hermes/bin:$PATH"; '
        r'if command -v hermes >/dev/null 2>&1 || [ -x /root/.hermes/bin/hermes ]; then '
        r'cd /root/hermes-agent && hermes pm doctor && hermes pm install cua-driver; '
        r'else echo "hermes CLI not installed; skipping PM verification"; fi',
        timeout: 900,
      );
      onProgress(const SetupState(
        step: SetupStep.installingHermesAgent,
        progress: 1.0,
        message: 'Hermes Agent installed',
      ));

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
    } on DioException catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Download failed: ${e.message}. Check your internet connection.',
      ));
    } catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Setup failed: $e',
      ));
    }
  }
}
