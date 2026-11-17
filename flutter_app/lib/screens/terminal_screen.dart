import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/terminal_toolbar.dart';
import '../services/terminal_manager.dart';
import '../services/native_bridge.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  late final TerminalManager _manager;
  final Map<int, TerminalController> _controllers = {};
  final Map<int, FocusNode> _focusNodes = {};
  final Map<int, GlobalKey<TerminalViewState>> _viewKeys = {};

  TerminalSession get _active => _manager.activeSession;

  TerminalController get _controller =>
      _controllers.putIfAbsent(_active.id, TerminalController.new);

  FocusNode get _terminalFocusNode =>
      _focusNodes.putIfAbsent(_active.id, FocusNode.new);

  GlobalKey<TerminalViewState> get _terminalViewKey => _viewKeys.putIfAbsent(
        _active.id,
        () => GlobalKey<TerminalViewState>(),
      );

  void _syncSessionWidgets() {
    final ids = _manager.sessions.map((s) => s.id).toSet();
    for (final id in _controllers.keys.toList()) {
      if (!ids.contains(id)) {
        _controllers.remove(id)?.dispose();
        _focusNodes.remove(id)?.dispose();
        _viewKeys.remove(id);
      }
    }
    for (final session in _manager.sessions) {
      _controllers.putIfAbsent(session.id, TerminalController.new);
      _focusNodes.putIfAbsent(session.id, FocusNode.new);
      _viewKeys.putIfAbsent(
        session.id,
        () => GlobalKey<TerminalViewState>(),
      );
    }
  }

  static final _anyUrlRegex = RegExp(r'https?://[^\s<>\[\]"' "'" r'\)]+');
  static final _boxDrawing = RegExp(r'[│┤├┬┴┼╮╯╰╭─╌╴╶┌┐└┘◇◆]+');

  static const _fontFallback = [
    'monospace',
    'Noto Sans Mono',
    'Noto Sans Mono CJK SC',
    'Noto Sans Mono CJK TC',
    'Noto Sans Mono CJK JP',
    'Noto Color Emoji',
    'Noto Sans Symbols',
    'Noto Sans Symbols 2',
    'sans-serif',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(WakelockPlus.enable());

    _manager = TerminalManager.instance;
    _syncSessionWidgets();
    _manager.addListener(_onManagerChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _manager.startShell();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(WakelockPlus.enable());
      unawaited(NativeBridge.stopTerminalService());
    } else if (state == AppLifecycleState.paused) {
      unawaited(WakelockPlus.disable());
      if (_manager.sessions.any((session) => session.isRunning)) {
        unawaited(NativeBridge.startTerminalService());
      }
    } else if (state == AppLifecycleState.detached) {
      unawaited(WakelockPlus.disable());
    }
  }

  void _onManagerChanged() {
    if (!mounted) return;
    _syncSessionWidgets();
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(WakelockPlus.disable());
    unawaited(NativeBridge.stopTerminalService());
    _manager.removeListener(_onManagerChanged);
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focus in _focusNodes.values) {
      focus.dispose();
    }

    // PTY dan Terminal dimiliki TerminalManager.
    // Jangan kill shell atau stop foreground service di sini.
    super.dispose();
  }

  String? _getSelectedText() {
    final selection = _controller.selection;
    if (selection == null || selection.isCollapsed) return null;

    final text = _active.terminal.buffer.getText(selection).trim();
    return text.isEmpty ? null : text;
  }

  void _showKeyboard() {
    _terminalFocusNode.requestFocus();
    _terminalViewKey.currentState?.requestKeyboard();
  }

  Future<void> _copyAll() async {
    final text = _active.terminal.buffer.getText();
    if (text.trim().isEmpty) return;

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All terminal logs copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  String? _extractUrl(String text) {
    final clean =
        text.replaceAll(_boxDrawing, '').replaceAll(RegExp(r'\s+'), '');
    final parts = clean.split(RegExp(r'(?=https?://)'));
    String? best;
    for (final part in parts) {
      final match = _anyUrlRegex.firstMatch(part);
      if (match != null) {
        final url = match.group(0)!;
        if (best == null || url.length > best.length) best = url;
      }
    }
    return best;
  }

  void _openSelection() {
    final text = _getSelectedText();
    if (text == null) return;
    final url = _extractUrl(text);
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No URL found in selection'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _manager.writeInput(data.text!);
    }
  }

  Widget _buildSessionTabs() {
    return Container(
      height: 14,
      color: const Color(0xFF11181F),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(
        children: [
          for (final session in _manager.sessions)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _manager.selectSession(session.id),
                onLongPress: () {
                  if (_manager.sessions.length > 1) {
                    _manager.closeSession(session.id);
                  }
                },
                child: Center(
                  child: Container(
                    height: 3,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: session.id == _active.id
                          ? const Color(0xFFEF4444)
                          : const Color(0xFF475569),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 25,
            height: 14,
            child: IconButton(
              tooltip: 'New session',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => _manager.createSession(),
              icon: const Icon(
                Icons.add,
                size: 17,
                color: Color(0xFF38BDF8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11181F),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 62,
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Terminal',
              style: TextStyle(
                fontSize: 16,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Color(0xFFF8FAFC),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _manager.isRunning
                        ? const Color(0xFF4ADE80)
                        : const Color(0xFFF59E0B),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _manager.isRunning
                      ? 'UBUNTU  •  CONNECTED'
                      : 'UBUNTU  •  STARTING',
                  style: const TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.1,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.keyboard_alt_outlined,
                size: 20, color: Color(0xFF38BDF8)),
            tooltip: 'Show keyboard',
            onPressed: _showKeyboard,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.copy_all_rounded,
                size: 19, color: Color(0xFF4ADE80)),
            tooltip: 'Copy all logs',
            onPressed: _copyAll,
          ),
          PopupMenuButton<String>(
            tooltip: 'Terminal actions',
            icon: const Icon(Icons.more_vert, color: Color(0xFFCBD5E1)),
            color: const Color(0xFF1B2532),
            onSelected: (value) {
              switch (value) {
                case 'open':
                  _openSelection();
                case 'clear':
                  _manager.clearTerminal();
                case 'paste':
                  _paste();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'paste',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.content_paste, color: Color(0xFF38BDF8)),
                  title: Text('Paste'),
                ),
              ),
              PopupMenuItem(
                value: 'open',
                child: ListTile(
                  dense: true,
                  leading:
                      Icon(Icons.open_in_browser, color: Color(0xFFA78BFA)),
                  title: Text('Open selected URL'),
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_sweep_outlined,
                      color: Color(0xFFFB7185)),
                  title: Text('Clear terminal'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _buildSessionTabs(),
          if (_active.loading)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Starting terminal...'),
                  ],
                ),
              ),
            )
          else if (_active.error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 48,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _active.error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () {
                          _manager.startShell(_active);
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            Expanded(
              child: Container(
                color: const Color(0xFF0B0F14),
                padding: const EdgeInsets.fromLTRB(7, 5, 7, 3),
                child: TerminalView(
                  _active.terminal,
                  key: _terminalViewKey,
                  controller: _controller,
                  focusNode: _terminalFocusNode,
                  autofocus: true,
                  keyboardType: TextInputType.multiline,
                  textStyle: const TerminalStyle(
                    fontSize: 13,
                    height: 1.15,
                    fontFamily: 'DejaVuSansMono',
                    fontFamilyFallback: _fontFallback,
                  ),
                  padding: const EdgeInsets.all(5),
                ),
              ),
            ),
            TerminalToolbar(
              key: ValueKey('toolbar-${_active.id}'),
              getPty: () => _active.pty,
              ctrlNotifier: _active.ctrlNotifier,
              altNotifier: _active.altNotifier,
              onClose: _manager.sessions.length > 1
                  ? () => _manager.closeSession(_active.id)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}
