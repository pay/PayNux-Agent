import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../app.dart';
import '../providers/gateway_provider.dart';
import '../services/native_bridge.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _autoScroll = true;
  String _filter = '';
  // Indices refer to the unfiltered provider log list, so a filter change
  // cannot silently select a different line.
  final Set<int> _selected = <int>{};
  bool _sharing = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _copy(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    _snack(message);
  }

  void _copyAll(List<String> logs) {
    if (logs.isEmpty) {
      _snack('No logs to copy');
      return;
    }
    _copy(logs.join('\n'), 'All logs copied');
  }

  void _copySelected(List<String> allLogs) {
    final lines = allLogs.asMap().entries
        .where((entry) => _selected.contains(entry.key))
        .map((entry) => entry.value)
        .toList();
    if (lines.isEmpty) {
      _snack('No lines selected');
      return;
    }
    _copy(lines.join('\n'), '${lines.length} line(s) copied');
  }

  void _toggleSelectAll(Iterable<int> visibleIndices) {
    final indices = visibleIndices.toList();
    setState(() {
      if (indices.isNotEmpty && indices.every(_selected.contains)) {
        _selected.removeAll(indices);
      } else {
        _selected.addAll(indices);
      }
    });
  }

  Future<void> _shareLogs(List<String> logs) async {
    final text = logs.join('\n');
    if (text.trim().isEmpty) {
      _snack('No logs to share');
      return;
    }
    setState(() => _sharing = true);
    try {
      // Native ACTION_SEND chooser == Android Share Sheet.
      final opened = await NativeBridge.shareText(text);
      if (!opened && mounted) _snack('Could not open the share sheet');
    } catch (e) {
      if (mounted) _snack('Share failed: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<GatewayProvider>();
    final logs = provider.logs;
    final visible = logs.asMap().entries
        .where(
          (entry) => _filter.isEmpty || entry.value.toLowerCase().contains(_filter),
        )
        .toList(growable: false);
    final allVisibleSelected =
        visible.isNotEmpty && visible.every((entry) => _selected.contains(entry.key));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gateway Logs'),
        actions: [
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.vertical_align_top,
            ),
            tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: allVisibleSelected ? 'Clear selection' : 'Select all (visible)',
            onPressed: () => _toggleSelectAll(visible.map((e) => e.key)),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: () => _copyAll(logs),
          ),
          IconButton(
            icon: _sharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share),
            tooltip: 'Share log',
            onPressed: _sharing ? null : () => _shareLogs(logs),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Filter logs...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _filter.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _filter = '');
                        },
                      )
                    : null,
              ),
              onChanged: (value) => setState(() => _filter = value.toLowerCase()),
            ),
          ),
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    '${_selected.length} selected',
                    style: theme.textTheme.labelMedium,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _copySelected(logs),
                    child: const Text('Copy selected'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Clear selection',
                    onPressed: () => setState(() => _selected.clear()),
                  ),
                ],
              ),
            ),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('No logs yet'))
                : _buildLogList(visible, theme),
          ),
        ],
      ),
    );
  }

  Widget _buildLogList(
    List<MapEntry<int, String>> visible,
    ThemeData theme,
  ) {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        final line = entry.value;
        final isSelected = _selected.contains(entry.key);
        final isError = line.toLowerCase().contains('error');
        final isWarn = line.toLowerCase().contains('warn');

        return Container(
          color: isSelected ? theme.colorScheme.primary.withAlpha(24) : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  line,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: isError
                        ? theme.colorScheme.error
                        : isWarn
                            ? AppColors.statusAmber
                            : theme.colorScheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy line',
                visualDensity: VisualDensity.compact,
                onPressed: () => _copy(line, 'Line copied'),
              ),
              IconButton(
                icon: Icon(
                  isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                ),
                tooltip: isSelected ? 'Deselect line' : 'Select line',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  if (isSelected) {
                    _selected.remove(entry.key);
                  } else {
                    _selected.add(entry.key);
                  }
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}
