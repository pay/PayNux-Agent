import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import '../app.dart';

class TerminalToolbar extends StatefulWidget {
  final Pty? Function() getPty;
  final ValueNotifier<bool> ctrlNotifier;
  final ValueNotifier<bool> altNotifier;
  final VoidCallback? onClose;

  const TerminalToolbar({
    super.key,
    required this.getPty,
    required this.ctrlNotifier,
    required this.altNotifier,
    this.onClose,
  });

  @override
  State<TerminalToolbar> createState() => _TerminalToolbarState();
}

class _TerminalToolbarState extends State<TerminalToolbar> {
  bool get _ctrlActive => widget.ctrlNotifier.value;
  bool get _altActive => widget.altNotifier.value;

  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    widget.ctrlNotifier.addListener(_refresh);
    widget.altNotifier.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.ctrlNotifier.removeListener(_refresh);
    widget.altNotifier.removeListener(_refresh);
    _pageController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _send(String data) {
    final pty = widget.getPty();
    if (pty == null) return;

    if (_ctrlActive) {
      widget.ctrlNotifier.value = false;

      if (data.length == 1) {
        final code = data.toLowerCase().codeUnitAt(0);
        if (code >= 97 && code <= 122) {
          pty.write(Uint8List.fromList([code - 96]));
          return;
        }
      }

      const ctrlMap = {
        '\x1b[A': '\x1b[1;5A',
        '\x1b[B': '\x1b[1;5B',
        '\x1b[C': '\x1b[1;5C',
        '\x1b[D': '\x1b[1;5D',
        '\x1b[H': '\x1b[1;5H',
        '\x1b[F': '\x1b[1;5F',
      };

      pty.write(utf8.encode(ctrlMap[data] ?? data));
      return;
    }

    if (_altActive) {
      widget.altNotifier.value = false;
      pty.write(utf8.encode('\x1b$data'));
      return;
    }

    pty.write(utf8.encode(data));
  }

  Widget _key(
    String label, {
    String? data,
    VoidCallback? onTap,
    bool active = false,
    double width = 40,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    final keyColor = switch (label) {
      'ESC' => const Color(0xFFF59E0B),
      'CTRL' => const Color(0xFFEF4444),
      'ALT' => const Color(0xFFA78BFA),
      'TAB' => const Color(0xFF38BDF8),
      'ENTER' => const Color(0xFF4ADE80),
      '^C' || '^D' => const Color(0xFFFB7185),
      '↑' || '↓' || '←' || '→' => const Color(0xFF38BDF8),
      'HOME' || 'END' || 'PGUP' || 'PGDN' => const Color(0xFFA78BFA),
      _ => const Color(0xFF94A3B8),
    };

    return SizedBox(
      width: width,
      height: 34,
      child: Material(
        color: active
            ? keyColor.withValues(alpha: 0.24)
            : dark
                ? const Color(0xFF202938)
                : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap ?? () => _send(data ?? label),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: active
                    ? keyColor
                    : dark
                        ? keyColor
                        : const Color(0xFF334155),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _keyRow(List<Widget> keys) {
    return Row(
      children: [
        for (final key in keys)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: key,
            ),
          ),
      ],
    );
  }

  Widget _buildPage(List<Widget> firstRow, List<Widget> secondRow) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _keyRow(firstRow),
          const SizedBox(height: 4),
          _keyRow(secondRow),
        ],
      ),
    );
  }

  Widget _pageDot(int index) {
    final selected = _currentPage == index;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: selected ? 12 : 4,
      height: 4,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF38BDF8)
            : Theme.of(context).brightness == Brightness.dark
                ? Colors.white30
                : Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    final navRow1 = [
      _key('ESC', data: '\x1b', width: double.infinity),
      _key('TAB', data: '\t', width: double.infinity),
      _key('HOME', data: '\x1b[H', width: double.infinity),
      _key('↑', data: '\x1b[A', width: double.infinity),
      _key('END', data: '\x1b[F', width: double.infinity),
      _key('PGUP', data: '\x1b[5~', width: double.infinity),
    ];

    final navRow2 = [
      _key('CTRL', width: double.infinity, active: _ctrlActive, onTap: () {
        widget.ctrlNotifier.value = !_ctrlActive;
        if (!_ctrlActive) widget.altNotifier.value = false;
      }),
      _key('ALT', width: double.infinity, active: _altActive, onTap: () {
        widget.altNotifier.value = !_altActive;
        if (!_altActive) widget.ctrlNotifier.value = false;
      }),
      _key('←', data: '\x1b[D', width: double.infinity),
      _key('↓', data: '\x1b[B', width: double.infinity),
      _key('→', data: '\x1b[C', width: double.infinity),
      _key('PGDN', data: '\x1b[6~', width: double.infinity),
    ];

    final symbolRow1 = [
      for (final symbol in ['/', '-', '|', '~', '_', ':', ';'])
        _key(symbol, data: symbol, width: double.infinity),
    ];

    final symbolRow2 = [
      for (final symbol in ['\\', r'$', '&', '*', '=', '>', '<'])
        _key(symbol, data: symbol, width: double.infinity),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
      decoration: BoxDecoration(
        color: dark ? AppColors.darkBg : const Color(0xFFE0E0E0),
        border: Border(
          top: BorderSide(
            color: dark ? AppColors.darkBorder : Colors.black12,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 72,
              child: Row(
                children: [
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      physics: const PageScrollPhysics(),
                      onPageChanged: (page) {
                        setState(() => _currentPage = page);
                      },
                      children: [
                        _buildPage(navRow1, navRow2),
                        _buildPage(symbolRow1, symbolRow2),
                      ],
                    ),
                  ),
                  if (widget.onClose != null)
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        tooltip: 'Close terminal session',
                        onPressed: widget.onClose,
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.close,
                          size: 19,
                          color: Color(0xFFEF4444),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 10,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [_pageDot(0), _pageDot(1)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
