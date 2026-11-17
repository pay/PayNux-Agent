import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/gateway_provider.dart';
import '../widgets/gateway_controls.dart';
import '../widgets/status_card.dart';
import 'configure_screen.dart';
import 'onboarding_screen.dart';
import 'terminal_screen.dart';
import 'logs_screen.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  static const Color _background = Color(0xFF0B0F14);
  static const Color _surface = Color(0xFF151B23);
  static const Color _elevated = Color(0xFF1E1E1E);
  static const Color _border = Color(0xFF374151);
  static const Color _red = Color(0xFFDC2626);
  static const Color _muted = Color(0xFF9CA3AF);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: const Color(0xFF11181F),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: const Row(
          children: [
            Icon(Icons.terminal, color: _red, size: 25),
            SizedBox(width: 10),
            Text(
              'PayNux Agent',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildBrandHeader(),
            const SizedBox(height: 22),

            _sectionLabel('GATEWAY'),
            const SizedBox(height: 10),
            const GatewayControls(),

            const SizedBox(height: 12),
            Consumer<GatewayProvider>(
              builder: (context, provider, _) {
                return _buildStatusCard(
                  theme,
                  'Gateway',
                  provider.statusLabel,
                  icon: provider.isRunning
                      ? Icons.cloud_done_rounded
                      : Icons.cloud_off_rounded,
                  color: provider.statusColor,
                );
              },
            ),

            const SizedBox(height: 26),
            _sectionLabel('QUICK ACTIONS'),
            const SizedBox(height: 10),

            _buildActionCard(
              title: 'Terminal',
              subtitle: 'Open your PayNux Linux shell',
              icon: Icons.terminal,
              featured: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TerminalScreen()),
              ),
            ),
            const SizedBox(height: 9),

            _buildActionCard(
              title: 'Onboarding',
              subtitle: 'Configure API keys and binding',
              icon: Icons.rocket_launch_outlined,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              ),
            ),
            const SizedBox(height: 9),

            _buildActionCard(
              title: 'Configure',
              subtitle: 'Manage gateway configuration',
              icon: Icons.tune_rounded,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConfigureScreen()),
              ),
            ),
            const SizedBox(height: 9),

            _buildActionCard(
              title: 'Logs',
              subtitle: 'Inspect gateway activity and logs',
              icon: Icons.article_outlined,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogsScreen()),
              ),
            ),

            const SizedBox(height: 22),
            Center(
              child: Text(
                'PAYNUX AGENT',
                style: TextStyle(
                  color: _muted.withAlpha(150),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandHeader() {
    return Row(
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFEF4444), Color(0xFFB91C1C)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(17),
            boxShadow: [
              BoxShadow(
                color: _red.withAlpha(55),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(
            Icons.terminal_rounded,
            color: Colors.white,
            size: 31,
          ),
        ),
        const SizedBox(width: 15),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PayNux Agent',
                style: TextStyle(
                  color: _red,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Your AI-powered Linux environment',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 3),
      child: Text(
        text,
        style: const TextStyle(
          color: _muted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    bool featured = false,
  }) {
    return Material(
      color: featured ? const Color(0xFF25171A) : _surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: featured ? _red.withAlpha(110) : _border,
              width: featured ? 1.1 : 0.7,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: featured
                      ? _red.withAlpha(35)
                      : _elevated,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  icon,
                  color: featured ? _red : Colors.white70,
                  size: 21,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: featured ? _red : _muted,
                size: 21,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard(
    ThemeData theme,
    String title,
    String value, {
    required IconData icon,
    required Color color,
  }) {
    return StatusCard(
      title: title,
      value: value,
      icon: icon,
      iconColor: color,
    );
  }
}
