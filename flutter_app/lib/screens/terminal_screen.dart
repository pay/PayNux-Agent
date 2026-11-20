import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/terminal_toolbar.dart';
import '../services/terminal_manager.dart';
import '../services/native_bridge.dart';

/// Copy-all helper kept pure so the toolbar behaviour can be tested without
/// a widget tree. Returns null when the terminal buffer has no visible text.
String? copyAllTerminalText(Terminal terminal) {
  final text = terminal.buffer.getText();
  return text.trim().isEmpty ? null : text;
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

/// Responsive sizing for the terminal AppBar. Kept pure so layout can be
/// verified at arbitrary logical widths without a device.
class TerminalHeaderMetrics {
  TerminalHeaderMetrics._({
    required this.isNarrow,
    required this.actionWidth,
    required this.actionIconSize,
    required this.badgeSize,
    required this.launcherSize,
    required this.leadingWidth,
    required this.showStatus,
  });

  final bool isNarrow;
  final double actionWidth;
  final double actionIconSize;
  final double badgeSize;
  final double launcherSize;
  final double leadingWidth;
  final bool showStatus;

  factory TerminalHeaderMetrics.of(double width) {
    final narrow = width < 360;
    return TerminalHeaderMetrics._(
      isNarrow: narrow,
      actionWidth: narrow ? 28 : 32,
      actionIconSize: narrow ? 17 : 19,
      badgeSize: narrow ? 40 : 48,
      launcherSize: narrow ? 32 : 40,
      leadingWidth: narrow ? 32 : 36,
      showStatus: width >= 360,
    );
  }

  /// Worst-case intrinsic width consumed by fixed header elements.
  /// The status slot is [Expanded] + ellipsis, so it takes only the
  /// remaining space and never forces an overflow.
  double fixedWidth({double actionCount = 7}) =>
      leadingWidth + (isNarrow ? 2 : 4) +
      badgeSize + (isNarrow ? 4 : 8) + 11 + actionCount * actionWidth + 4;
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  late final TerminalManager _manager;
  final Map<int, TerminalController> _controllers = {};
  final Map<int, FocusNode> _focusNodes = {};
  final Map<int, GlobalKey<TerminalViewState>> _viewKeys = {};

  // Raw pointer tracking for the terminal long-press context menu. It sits
  // alongside xterm's own long-press word selection instead of replacing it.
  int? _longPressPointerId;
  DateTime? _longPressDownAt;
  Offset? _longPressDownPos;
  bool _longPressMoved = false;

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

  static const _terminalTheme = TerminalTheme(
    cursor: Color(0xFFFFFFFF),
    selection: Color(0x66DC2626),
    foreground: Color(0xFFE8EEF5),
    background: Color(0xFF0B0F14),
    black: Color(0xFF111827),
    red: Color(0xFFFF6B6B),
    green: Color(0xFF4ADE80),
    yellow: Color(0xFFFACC15),
    blue: Color(0xFF60A5FA),
    magenta: Color(0xFFC084FC),
    cyan: Color(0xFF22D3EE),
    white: Color(0xFFF8FAFC),
    brightBlack: Color(0xFF64748B),
    brightRed: Color(0xFFFF8E8E),
    brightGreen: Color(0xFF86EFAC),
    brightYellow: Color(0xFFFDE047),
    brightBlue: Color(0xFF93C5FD),
    brightMagenta: Color(0xFFD8B4FE),
    brightCyan: Color(0xFF67E8F9),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: Color(0xFF31FF26),
    searchHitForeground: Color(0xFF000000),
  );

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

  /// Toolbar Copy copies the whole visible terminal buffer, no selection
  /// required. An empty terminal is a no-op.
  void _copyAll() {
    final text = copyAllTerminalText(_active.terminal);
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  /// Context-menu Copy copies only the xterm selection captured when the
  /// menu opened, so a later tap outside the terminal cannot clear it first.
  void _copySelected(String? text) {
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  void _onTerminalPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus) {
      return;
    }
    _longPressPointerId = event.pointer;
    _longPressDownAt = DateTime.now();
    _longPressDownPos = event.position;
    _longPressMoved = false;
  }

  void _onTerminalPointerMove(PointerMoveEvent event) {
    if (event.pointer != _longPressPointerId || _longPressDownPos == null) {
      return;
    }
    if ((event.position - _longPressDownPos!).distance > 12) {
      _longPressMoved = true;
    }
  }

  void _onTerminalPointerUp(PointerUpEvent event) {
    if (event.pointer != _longPressPointerId) return;
    final heldMs = DateTime.now().difference(_longPressDownAt!).inMilliseconds;
    final moved = _longPressMoved;
    _longPressPointerId = null;
    _longPressDownAt = null;
    _longPressDownPos = null;
    _longPressMoved = false;
    if (heldMs >= 500 && !moved && mounted) {
      _showTerminalContextMenu(event.position);
    }
  }

  void _onTerminalPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _longPressPointerId) return;
    _longPressPointerId = null;
    _longPressDownAt = null;
    _longPressDownPos = null;
    _longPressMoved = false;
  }

  Future<void> _showTerminalContextMenu(Offset position) async {
    // xterm selected the word on long-press start. Snapshot it before the
    // menu route takes focus, and defer opening until after this pointer-up
    // event has finished dispatching (otherwise the popup can be dismissed
    // immediately on Android).
    final selectedText = _getSelectedText();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final rect = Rect.fromCircle(center: position, radius: 0);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        rect,
        Offset.zero & MediaQuery.of(context).size,
      ),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.copy, color: Color(0xFF4ADE80)),
            title: Text('Copy'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'paste',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.paste, color: Color(0xFF38BDF8)),
            title: Text('Paste'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'more',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.more_horiz, color: Color(0xFFA78BFA)),
            title: Text('More'),
          ),
        ),
      ],
    );
    if (value == null || !mounted) return;
    switch (value) {
      case 'copy':
        _copySelected(selectedText);
      case 'paste':
        await _paste();
      case 'more':
        await _showTerminalMoreMenu(position);
    }
  }

  Future<void> _showTerminalMoreMenu(Offset position) async {
    final rect = Rect.fromCircle(center: position, radius: 0);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        rect,
        Offset.zero & MediaQuery.of(context).size,
      ),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'keyboard',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.keyboard_alt_outlined, color: Color(0xFF38BDF8)),
            title: Text('Show keyboard'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'open',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.open_in_browser, color: Color(0xFFA78BFA)),
            title: Text('Open selected URL'),
          ),
        ),
      ],
    );
    if (value != null) _onOverflowSelected(value);
  }

  void _sendEnter() {
    _manager.writeInput('\r');
    _showKeyboard();
  }

  void _closeActiveSession() {
    if (_manager.sessions.length > 1) {
      _manager.closeSession(_active.id);
    }
  }

  Future<void> _showOverflowMenu(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final value = await showMenu<String>(
      context: buttonContext,
      position: RelativeRect.fromRect(
        rect,
        Offset.zero & MediaQuery.of(buttonContext).size,
      ),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'keyboard',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.keyboard_alt_outlined, color: Color(0xFF38BDF8)),
            title: Text('Show keyboard'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'open',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.open_in_browser, color: Color(0xFFA78BFA)),
            title: Text('Open selected URL'),
          ),
        ),
      ],
    );
    if (value != null) _onOverflowSelected(value);
  }

  void _onOverflowSelected(String value) {
    switch (value) {
      case 'keyboard':
        _showKeyboard();
      case 'open':
        _openSelection();
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
    final screenWidth = MediaQuery.of(context).size.width;
    final header = TerminalHeaderMetrics.of(screenWidth);
    final isNarrow = header.isNarrow;
    final actionWidth = header.actionWidth;
    final actionIconSize = header.actionIconSize;
    final badgeSize = header.badgeSize;
    final launcherSize = header.launcherSize;
    final leadingWidth = header.leadingWidth;
    final showStatus = header.showStatus;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11181F),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 56,
        titleSpacing: isNarrow ? 2 : 4,
        title: Row(
          children: [
            Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                color: const Color(0xFF151B23),
                borderRadius: BorderRadius.circular(isNarrow ? 10 : 12),
              ),
              child: Image.asset(
                'assets/paynux_launcher.png',
                width: launcherSize,
                height: launcherSize,
                fit: BoxFit.contain,
              ),
            ),
            SizedBox(width: isNarrow ? 4 : 8),
            Expanded(
              child: showStatus
                  ? Row(
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
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _manager.isRunning
                                ? 'UBUNTU  •  CONNECTED'
                                : 'UBUNTU  •  STARTING',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              letterSpacing: 0.8,
                              color: Color(0xFF94A3B8),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
        leading: SizedBox(
          width: leadingWidth,
          child: IconButton(
            constraints: BoxConstraints.tightFor(width: leadingWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.arrow_back, size: actionIconSize),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.copy_all_rounded, size: actionIconSize, color: const Color(0xFFE2E8F0)),
            tooltip: 'Copy all terminal log',
            onPressed: _copyAll,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.content_paste, size: actionIconSize, color: const Color(0xFF38BDF8)),
            tooltip: 'Paste',
            onPressed: _paste,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.delete_sweep_outlined, size: actionIconSize, color: const Color(0xFFFB7185)),
            tooltip: 'Clear terminal',
            onPressed: () => _manager.clearTerminal(),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.add, size: actionIconSize, color: const Color(0xFF4ADE80)),
            tooltip: 'New session',
            onPressed: () => _manager.createSession(),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.keyboard_return, size: actionIconSize, color: const Color(0xFF4ADE80)),
            tooltip: 'Send Enter',
            onPressed: _sendEnter,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.close, size: actionIconSize, color: const Color(0xFFEF4444)),
            tooltip: 'Close session',
            onPressed: _manager.sessions.length > 1 ? _closeActiveSession : null,
          ),
          Builder(
            builder: (buttonContext) => SizedBox(
              width: actionWidth,
              height: 40,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                constraints: BoxConstraints.tightFor(width: actionWidth, height: 40),
                padding: EdgeInsets.zero,
                icon: Icon(
                  Icons.more_vert,
                  size: actionIconSize,
                  color: const Color(0xFFCBD5E1),
                ),
                tooltip: 'More terminal actions',
                onPressed: () => _showOverflowMenu(buttonContext),
              ),
            ),
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
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onTerminalPointerDown,
                  onPointerMove: _onTerminalPointerMove,
                  onPointerUp: _onTerminalPointerUp,
                  onPointerCancel: _onTerminalPointerCancel,
                  child: TerminalView(
                    _active.terminal,
                    key: _terminalViewKey,
                    controller: _controller,
                    focusNode: _terminalFocusNode,
                    autofocus: true,
                    keyboardType: TextInputType.multiline,
                    theme: _terminalTheme,
                    textStyle: const TerminalStyle(
                      fontSize: 13.5,
                      height: 1.2,
                      fontFamily: 'DejaVuSansMono',
                      fontFamilyFallback: _fontFallback,
                    ),
                    padding: const EdgeInsets.all(5),
                  ),
                ),
              ),
            ),
            TerminalToolbar(
              key: ValueKey('toolbar-${_active.id}'),
              getPty: () => _active.pty,
              ctrlNotifier: _active.ctrlNotifier,
              altNotifier: _active.altNotifier,
            ),
          ],
        ],
      ),
    );
  }
}
