import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../constants.dart';
import '../services/native_bridge.dart';
import '../services/preferences_service.dart';
import 'setup_wizard_screen.dart';
import 'dashboard_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  String _status = 'Loading...';
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();
    _checkAndRoute();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _checkAndRoute() async {
    await Future.delayed(const Duration(milliseconds: 500));

    try {
      setState(() => _status = 'Checking setup status...');

      try {
        await NativeBridge.setupDirs();
      } catch (_) {}
      // Authoritative DNS config: failure is surfaced by the outer catch.
      await NativeBridge.ensureDnsConfig();

      final prefs = PreferencesService();
      await prefs.init();

      // Auto-export snapshot when app version changes
      try {
        final oldVersion = prefs.lastAppVersion;
        if (oldVersion != null && oldVersion != AppConstants.version) {
          final hasPermission = await NativeBridge.hasStoragePermission();
          if (hasPermission) {
            final sdcard = await NativeBridge.getExternalStoragePath();
            final downloadDir = Directory('$sdcard/Download');
            if (!await downloadDir.exists()) {
              await downloadDir.create(recursive: true);
            }
            final snapshotPath =
                '$sdcard/Download/hermes-snapshot-$oldVersion.json';
            final hermesConfig =
                await NativeBridge.readRootfsFile('root/.hermes/config.yaml');
            final snapshot = {
              'version': oldVersion,
              'timestamp': DateTime.now().toIso8601String(),
              'hermesConfig': hermesConfig,
              'autoStart': prefs.autoStartGateway,
            };
            await File(snapshotPath).writeAsString(
              const JsonEncoder.withIndent('  ').convert(snapshot),
            );
          }
        }
        prefs.lastAppVersion = AppConstants.version;
      } catch (_) {}

      bool setupComplete;
      try {
        setupComplete = await NativeBridge.isBootstrapComplete();
      } catch (_) {
        setupComplete = false;
      }

      // Auto-repair
      if (!setupComplete) {
        try {
          final status = await NativeBridge.getBootstrapStatus();
          final rootfsOk = status['rootfsExists'] == true;
          final bashOk = status['binBashExists'] == true;
          final pythonOk = status['pythonInstalled'] == true;
          final hermesOk = status['hermesInstalled'] == true;

          if (rootfsOk && bashOk) {
            if (!pythonOk) {
              setState(() => _status = 'Reinstalling Python...');
              final result = await NativeBridge.runInProot(
                'apt-get update -y && apt-get install -y python3 python3-venv python3-pip',
                timeout: 600,
              );
              debugPrint('[StartupRepair] Python repair output: $result');
            }
            if (!hermesOk) {
              setState(() => _status = 'Reinstalling Hermes Agent...');
              final result = await NativeBridge.runInProot(
                'cd /root/hermes-agent && UV_LINK_MODE=copy ./setup-hermes.sh --runtime-only',
                timeout: 1800,
              );
              debugPrint('[StartupRepair] Hermes repair output: $result');
            }
            setupComplete = await NativeBridge.isBootstrapComplete();
          }
        } catch (e, st) {
          debugPrint('[StartupRepair] Repair failed: $e');
          debugPrintStack(stackTrace: st);
          setupComplete = false;
        }
      }

      if (!mounted) return;

      if (setupComplete) {
        prefs.setupComplete = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DashboardScreen()),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const SetupWizardScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/ic_launcher.png',
                width: 80,
                height: 80,
              ),
              const SizedBox(height: 24),
              Text(
                'PayNux Agent',
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your AI. Your Terminal. Your Control.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'POWERED BY HERMES ENGINE',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 32),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _status,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
