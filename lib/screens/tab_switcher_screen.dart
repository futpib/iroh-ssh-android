import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';

enum TabSwitcherAction { switchTo, close, add }

class TabSwitcherResult {
  final TabSwitcherAction action;
  final int index;
  final String? newViewStyle;

  const TabSwitcherResult(this.action, this.index, {this.newViewStyle});
}

class TabSwitcherScreen extends StatefulWidget {
  final List<SshSessionInfo> sessions;
  final int currentIndex;
  final String viewStyle;

  const TabSwitcherScreen({
    super.key,
    required this.sessions,
    required this.currentIndex,
    required this.viewStyle,
  });

  @override
  State<TabSwitcherScreen> createState() => _TabSwitcherScreenState();
}

class _TabSwitcherScreenState extends State<TabSwitcherScreen> {
  late String _viewStyle;

  @override
  void initState() {
    super.initState();
    _viewStyle = widget.viewStyle;
  }

  void _switchTo(int index) {
    Navigator.pop(
      context,
      TabSwitcherResult(TabSwitcherAction.switchTo, index,
          newViewStyle: _viewStyle != widget.viewStyle ? _viewStyle : null),
    );
  }

  void _close(int index) {
    Navigator.pop(
      context,
      TabSwitcherResult(TabSwitcherAction.close, index,
          newViewStyle: _viewStyle != widget.viewStyle ? _viewStyle : null),
    );
  }

  void _add() {
    Navigator.pop(
      context,
      TabSwitcherResult(TabSwitcherAction.add, -1,
          newViewStyle: _viewStyle != widget.viewStyle ? _viewStyle : null),
    );
  }

  void _toggleViewStyle() {
    setState(() {
      _viewStyle = _viewStyle == 'list' ? 'grid' : 'list';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.sessions.length} tab${widget.sessions.length != 1 ? 's' : ''}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(
            context,
            _viewStyle != widget.viewStyle
                ? TabSwitcherResult(TabSwitcherAction.switchTo,
                    widget.currentIndex,
                    newViewStyle: _viewStyle)
                : null,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_viewStyle == 'list' ? Icons.grid_view : Icons.view_list),
            onPressed: _toggleViewStyle,
            tooltip: _viewStyle == 'list' ? 'Grid view' : 'List view',
          ),
        ],
      ),
      body: _viewStyle == 'list' ? _buildListView(theme) : _buildGridView(theme),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildListView(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: widget.sessions.length,
      itemBuilder: (context, i) {
        final session = widget.sessions[i];
        final isCurrent = i == widget.currentIndex;

        return Dismissible(
          key: ValueKey(session.sessionId),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: theme.colorScheme.error,
            child: Icon(Icons.close, color: theme.colorScheme.onError),
          ),
          onDismissed: (_) => _close(i),
          child: ColoredBox(
            color: isCurrent
                ? theme.colorScheme.primaryContainer.withAlpha(80)
                : Colors.transparent,
            child: ListTile(
            leading: Icon(
              Icons.terminal,
              color: isCurrent
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(
              session.displayName,
              overflow: TextOverflow.ellipsis,
              style: isCurrent
                  ? TextStyle(fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary)
                  : null,
            ),
            subtitle: Text(
              session.connectionType.label,
              style: theme.textTheme.bodySmall,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => _close(i),
            ),
            onTap: () => _switchTo(i),
          ),
          ),
        );
      },
    );
  }

  Widget _buildGridView(ThemeData theme) {
    return GridView.builder(
      padding: const EdgeInsets.all(8).copyWith(bottom: 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.0,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: widget.sessions.length,
      itemBuilder: (context, i) {
        final session = widget.sessions[i];
        final isCurrent = i == widget.currentIndex;

        return GestureDetector(
          onTap: () => _switchTo(i),
          child: Card(
            elevation: isCurrent ? 4 : 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: isCurrent
                  ? BorderSide(color: theme.colorScheme.primary, width: 2)
                  : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  height: 40,
                  color: isCurrent
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      Icon(
                        Icons.terminal,
                        size: 16,
                        color: isCurrent
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          session.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight:
                                isCurrent ? FontWeight.bold : FontWeight.normal,
                            color: isCurrent
                                ? theme.colorScheme.primary
                                : null,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          icon: const Icon(Icons.close),
                          onPressed: () => _close(i),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    color: theme.colorScheme.surfaceContainerLow,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.terminal,
                          size: 40,
                          color: theme.colorScheme.onSurfaceVariant
                              .withAlpha(100),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          session.connectionType.label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withAlpha(150),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
