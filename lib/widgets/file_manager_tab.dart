import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/services/fs/ipc_remote_fs.dart';
import 'package:iroh_ssh_app/services/fs/local_fs.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:iroh_ssh_app/services/fs/sftp_fs.dart';
import 'package:iroh_ssh_app/services/fs/upload_naming.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/transfer_notification.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/widgets/session_tab_controller.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A file-manager tab: browses an SFTP filesystem (iroh / ssh) or the local
/// device filesystem (local), with download / upload / mkdir / rename / delete.
///
/// Mirrors [TerminalTab]'s dual mode: on Android it is a thin client over the
/// background service (via [IpcRemoteFs]); on desktop it talks to a real
/// [SftpFs] / [LocalFs] in-process.
class FileManagerTab extends StatefulWidget {
  final SshSessionInfo session;
  final VoidCallback onDisconnected;

  @visibleForTesting
  final bool connectOnInit;

  /// Test-only: drive the tab against a fake filesystem instead of connecting.
  @visibleForTesting
  final RemoteFs? testFs;

  const FileManagerTab({
    super.key,
    required this.session,
    required this.onDisconnected,
    this.connectOnInit = true,
    this.testFs,
  });

  @override
  State<FileManagerTab> createState() => FileManagerTabState();
}

class FileManagerTabState extends State<FileManagerTab>
    with AutomaticKeepAliveClientMixin
    implements SessionTabController {
  static final bool _isAndroid = Platform.isAndroid;

  RemoteFs? _fs;
  IpcRemoteFs? _ipc; // non-null in IPC (Android) mode
  SSHClient? _client; // non-null in direct (desktop) ssh/iroh mode

  String _cwd = '';
  List<FsEntry> _entries = [];
  final Map<String, List<FsEntry>> _directoryCache = {};
  bool _ready = false;
  bool _loading = false;
  bool _hasListing = false;
  String? _error;
  int _navigationGeneration = 0;
  final _repaintBoundaryKey = GlobalKey();

  void Function(Object)? _serviceDataCallback;

  @override
  bool get wantKeepAlive => true;

  @override
  bool get shellReady => _ready;

  // FileManager has no terminal focus to manage.
  @override
  void requestFocus() {}
  @override
  void disableFocus() {}
  @override
  void enableFocus() {}

  @override
  void initState() {
    super.initState();
    final injected = widget.testFs;
    if (injected != null) {
      _fs = injected;
      WidgetsBinding.instance.addPostFrameCallback((_) => _onReady());
      return;
    }
    if (widget.connectOnInit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isAndroid) {
          _attachToService();
        } else {
          _connectDirect();
        }
      });
    }
  }

  /// Current directory (test-only accessor).
  @visibleForTesting
  String get cwd => _cwd;

  Future<ui.Image?> captureImage({double pixelRatio = 1.0}) async {
    final boundary = _repaintBoundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    try {
      return await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }

  /// Handle the Android system back button: go up one directory if possible.
  /// Returns true when the back was consumed (so the app shouldn't also exit).
  @override
  bool handleBack() {
    if (_ready && _canGoUp) {
      _up();
      return true;
    }
    return false;
  }

  // =========================================================================
  // IPC mode (Android) — proxy SFTP through the background service
  // =========================================================================

  void _attachToService() {
    final ipc = IpcRemoteFs(
      sessionId: widget.session.sessionId,
      send: FlutterForegroundTask.sendDataToTask,
    );
    _ipc = ipc;
    _fs = ipc;

    _serviceDataCallback = _onServiceData;
    FlutterForegroundTask.addTaskDataCallback(_serviceDataCallback!);
    FlutterForegroundTask.sendDataToTask(
      AttachCommand(sessionId: widget.session.sessionId).encode(),
    );
  }

  void _onServiceData(Object data) {
    if (data is! String) return;
    try {
      final event = ServiceEvent.decode(data);
      // Route SFTP responses to the proxy first.
      _ipc?.handleEvent(event);
      switch (event) {
        case ShellReadyEvent() when event.sessionId == widget.session.sessionId:
          if (!_ready) _onReady();
        case AuthPromptEvent()
            when event.sessionId == widget.session.sessionId:
          _handleAuthPrompt(event.prompt, event.echo);
        case DisconnectedEvent()
            when event.sessionId == widget.session.sessionId:
          if (mounted) widget.onDisconnected();
        case ErrorEvent() when event.sessionId == widget.session.sessionId:
          if (mounted) setState(() => _error = event.message);
        case SftpDoneEvent() when event.sessionId == widget.session.sessionId:
          // A background transfer finished; refresh so a just-uploaded file
          // shows up. Progress/cancel live entirely in the notification.
          if (_ready) _refresh();
        default:
          break;
      }
    } catch (_) {}
  }

  Future<void> _handleAuthPrompt(String prompt, bool echo) async {
    final response = await _promptText('Authentication', prompt, obscure: !echo);
    FlutterForegroundTask.sendDataToTask(AuthResponseCommand(
      sessionId: widget.session.sessionId,
      response: response ?? '',
    ).encode());
  }

  // =========================================================================
  // Direct mode (non-Android)
  // =========================================================================

  void _connectDirect() {
    switch (widget.session.connectionType) {
      case ConnectionType.iroh:
      case ConnectionType.ssh:
        _connectSshDirect();
      case ConnectionType.local:
        _connectLocalDirect();
    }
  }

  Future<void> _connectSshDirect() async {
    try {
      final keys = await KeyStorage.instance.listKeys();
      final identities = keys.map((k) => k.keyPair).toList();
      final socket = await SSHSocket.connect(
          widget.session.host, widget.session.port);
      final client = SSHClient(
        socket,
        username: widget.session.username,
        identities: identities,
        onPasswordRequest: () async =>
            await _promptText('Authentication', 'Password:', obscure: true) ??
            '',
        onUserInfoRequest: (request) async {
          final responses = <String>[];
          for (final prompt in request.prompts) {
            responses.add(await _promptText(
                  'Authentication',
                  prompt.promptText,
                  obscure: !prompt.echo,
                ) ??
                '');
          }
          return responses;
        },
      );
      _client = client;
      _fs = SftpFs(await client.sftp());
      await _onReady();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _connectLocalDirect() async {
    _fs = LocalFs();
    await _onReady();
  }

  // =========================================================================
  // Shared
  // =========================================================================

  Future<void> _onReady() async {
    if (!mounted) return;
    setState(() {
      _ready = true;
      _loading = true;
    });
    try {
      final dir = await _fs!.initialDir();
      if (!mounted) return;
      await _navigateTo(dir);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _messageOf(e);
        });
      }
    }
  }

  Future<void> _navigateTo(String path) async {
    // Paint the last successful listing for this path immediately, then
    // replace it after the remote filesystem responds.
    final generation = ++_navigationGeneration;
    final cachedEntries = _directoryCache[path];
    final previousPath = _cwd;
    final previousEntries = _entries;
    final hadPreviousListing = _hasListing;

    setState(() {
      _cwd = path;
      _entries = cachedEntries ?? const <FsEntry>[];
      _hasListing = cachedEntries != null;
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _fs!.list(path);
      _sortEntries(entries);
      // A slower request for a directory the user already left must not replace
      // the visible listing selected by a newer navigation.
      if (!mounted || generation != _navigationGeneration) return;
      final snapshot = List<FsEntry>.unmodifiable(entries);
      _directoryCache[path] = snapshot;
      setState(() {
        _entries = snapshot;
        _hasListing = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _navigationGeneration) return;
      setState(() {
        _loading = false;
        if (cachedEntries == null && hadPreviousListing) {
          _cwd = previousPath;
          _entries = previousEntries;
          _hasListing = true;
        } else if (cachedEntries == null) {
          _error = _messageOf(e);
        }
      });
      _showError(e);
    }
  }

  Future<void> _refresh() => _navigateTo(_cwd);

  bool get _canGoUp =>
      _fs != null && _cwd.isNotEmpty && _fs!.parentOf(_cwd) != _cwd;

  void _up() {
    final parent = _fs!.parentOf(_cwd);
    if (parent != _cwd) _navigateTo(parent);
  }

  Future<void> _onTapEntry(FsEntry entry) async {
    if (entry.isDir) {
      await _navigateTo(entry.path);
    } else if (entry.isLink) {
      try {
        final resolved = await _fs!.stat(entry.path, followLink: true);
        if (resolved.isDir) {
          await _navigateTo(entry.path);
        } else {
          _showEntryActions(entry);
        }
      } catch (e) {
        _showError(e);
      }
    } else {
      _showEntryActions(entry);
    }
  }

  Future<void> _mkdir() async {
    final name = await _promptText('New folder', 'Folder name');
    if (name == null || name.isEmpty) return;
    try {
      await _fs!.mkdir(_fs!.join(_cwd, name));
      await _navigateTo(_cwd);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _rename(FsEntry entry) async {
    final name =
        await _promptText('Rename', 'New name', initial: entry.name);
    if (name == null || name.isEmpty || name == entry.name) return;
    try {
      await _fs!.rename(entry.path, _fs!.join(_cwd, name));
      await _navigateTo(_cwd);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _delete(FsEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(entry.isDir
            ? 'This will delete the folder and all its contents.'
            : 'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _fs!.remove(entry.path, recursive: entry.isDir);
      await _navigateTo(_cwd);
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _download(FsEntry entry) async {
    if (_isAndroid) {
      // Hand the whole job to the background service: it streams the bytes to a
      // cache file, publishes to public Downloads, and shows a progress
      // notification (with Cancel) — all off the UI isolate.
      final tmp = p.join((await getTemporaryDirectory()).path, entry.name);
      _ipc!.startDownload(entry.path, tmp, publishName: entry.name);
      _toast('Downloading ${entry.name} — see the notification for progress');
      return;
    }
    // Desktop: no foreground service — run it in-process to a chosen directory.
    final dir = await FilePicker.platform.getDirectoryPath(
      initialDirectory: (await getDownloadsDirectory())?.path,
    );
    if (dir == null) return;
    final localPath = p.join(dir, entry.name);
    _toast('Downloading ${entry.name}…');
    try {
      await _fs!.download(entry.path, localPath).drain<void>();
      _toast('Saved to $localPath');
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _upload() async {
    final picked = await FilePicker.platform.pickFiles();
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final localPath = file.path;
    if (localPath == null) {
      _toast('Could not access the selected file');
      return;
    }
    if (_isAndroid) {
      // The service resolves a non-clobbering name and shows progress in a
      // notification — just hand it the intended target.
      _ipc!.startUpload(localPath, _fs!.join(_cwd, file.name));
      _toast('Uploading ${file.name} — see the notification for progress');
      return;
    }
    // Desktop: pick a non-clobbering name, run it in-process, then refresh.
    final remotePath = await resolveUploadTarget(
      dir: _cwd,
      name: file.name,
      join: _fs!.join,
      listNames: (dir) async =>
          (await _fs!.list(dir)).map((e) => e.name).toList(),
    );
    _toast('Uploading ${file.name}…');
    try {
      await _fs!.upload(localPath, remotePath).drain<void>();
      await _navigateTo(_cwd);
    } catch (e) {
      _showError(e);
    }
  }

  // =========================================================================
  // Small UI helpers
  // =========================================================================

  void _showEntryActions(FsEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.name),
              subtitle: Text(_entrySubtitle(entry)),
            ),
            const Divider(height: 0),
            if (!entry.isDir)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(entry);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                _delete(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptText(
    String title,
    String label, {
    String? initial,
    bool obscure = false,
  }) {
    // The dialog owns its TextEditingController (disposed in its own dispose,
    // after the route is fully gone) — disposing it here, right after the
    // await, crashes because the dialog is still animating out.
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PromptDialog(
        title: title,
        label: label,
        initial: initial,
        obscure: obscure,
      ),
    );
  }

  String _messageOf(Object e) =>
      e is RemoteFsException ? e.message : e.toString();

  void _showError(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_messageOf(e))));
    }
  }

  void _toast(String msg) {
    if (_isAndroid) {
      Fluttertoast.showToast(msg: msg);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _entrySubtitle(FsEntry entry) {
    final parts = <String>[];
    if (entry.isDir) {
      parts.add('Folder');
    } else if (entry.isLink) {
      parts.add('Link');
    } else if (entry.size != null) {
      parts.add(fmtSize(entry.size!));
    }
    if (entry.mtime != null) {
      parts.add(_fmtDate(DateTime.fromMillisecondsSinceEpoch(
          entry.mtime! * 1000)));
    }
    return parts.join('  ·  ');
  }

  static String _fmtDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  void dispose() {
    // Transfers are owned by the background service (they keep running and stay
    // controllable from their notification), so closing the tab doesn't touch
    // them — it just detaches.
    if (_isAndroid) {
      // Detach but keep the session alive (mirrors TerminalTab).
      if (_serviceDataCallback != null) {
        FlutterForegroundTask.removeTaskDataCallback(_serviceDataCallback!);
        _serviceDataCallback = null;
      }
      FlutterForegroundTask.sendDataToTask(
        DetachCommand(sessionId: widget.session.sessionId).encode(),
      );
    } else {
      _client?.close();
      _fs?.close();
      if (widget.connectOnInit &&
          widget.session.connectionType == ConnectionType.iroh) {
        disconnectIroh(port: widget.session.port);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return RepaintBoundary(
      key: _repaintBoundaryKey,
      child: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: SafeArea(
              top: true,
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: 'Up',
                    onPressed: _ready && _canGoUp ? _up : null,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          _cwd.isEmpty ? '…' : _cwd,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh',
                    onPressed: _ready ? _refresh : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: 'New folder',
                    onPressed: _ready ? _mkdir : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.upload_file),
                    tooltip: 'Upload',
                    onPressed: _ready ? _upload : null,
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (!_ready) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      );
    }
    if (!_hasListing) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(
                _error ?? 'Empty folder',
                textAlign: TextAlign.center,
                style: _error == null
                    ? null
                    : TextStyle(color: theme.colorScheme.error),
              ),
      );
    }

    final listing = _entries.isEmpty
        ? RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              children: const [
                SizedBox(height: 120),
                Center(child: Text('Empty folder')),
              ],
            ),
          )
        : RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final entry = _entries[i];
                return ListTile(
                  leading: Icon(
                    entry.isDir
                        ? Icons.folder
                        : entry.isLink
                        ? Icons.link
                        : Icons.insert_drive_file_outlined,
                    color: entry.isDir ? theme.colorScheme.primary : null,
                  ),
                  title: Text(entry.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_entrySubtitle(entry)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'download':
                          _download(entry);
                        case 'rename':
                          _rename(entry);
                        case 'delete':
                          _delete(entry);
                      }
                    },
                    itemBuilder: (ctx) => [
                      if (!entry.isDir)
                        const PopupMenuItem(
                            value: 'download', child: Text('Download')),
                      const PopupMenuItem(
                          value: 'rename', child: Text('Rename')),
                      const PopupMenuItem(
                          value: 'delete', child: Text('Delete')),
                    ],
                  ),
                  onTap: () => _onTapEntry(entry),
                  onLongPress: () => _showEntryActions(entry),
                );
              },
            ),
          );

    return Stack(
      children: [
        Positioned.fill(child: listing),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              key: Key('directory-refresh-indicator'),
              minHeight: 2,
              semanticsLabel: 'Refreshing directory',
            ),
          ),
      ],
    );
  }

  static void _sortEntries(List<FsEntry> entries) {
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }
}

/// Text-input dialog that owns its [TextEditingController]. The controller is
/// disposed in [State.dispose] — i.e. only after the route is fully removed —
/// avoiding the use-after-dispose crash from disposing it right after `await
/// showDialog` (while the dialog is still animating out).
class _PromptDialog extends StatefulWidget {
  final String title;
  final String label;
  final String? initial;
  final bool obscure;

  const _PromptDialog({
    required this.title,
    required this.label,
    this.initial,
    this.obscure = false,
  });

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: widget.obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('OK')),
      ],
    );
  }
}
