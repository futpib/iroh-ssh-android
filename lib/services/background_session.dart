import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/services/fs/local_fs.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:iroh_ssh_app/services/fs/sftp_fs.dart';
import 'package:iroh_ssh_app/services/fs/upload_naming.dart';
import 'package:iroh_ssh_app/services/media_store.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/terminal_replay_buffer.dart';
import 'package:iroh_ssh_app/services/transfer_notification.dart';
import 'package:iroh_ssh_app/services/transfer_notifications.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:path/path.dart' as p;

enum SessionState { connecting, connected, disconnected }

/// Bookkeeping for one in-flight SFTP/local transfer: enough to drive its
/// progress notification (direction, name, size, progress), publish a finished
/// download, and abort it. Held in [BackgroundSession._activeTransfers], keyed
/// by requestId. All of this lives in the foreground-service isolate.
class TransferInfo {
  final String label;
  final bool isUpload;

  /// Local file the bytes are written to (download) or read from (upload). For
  /// a download this is a temp/cache path that is cleaned up afterwards.
  final String localPath;

  /// For a download: if set, publish [localPath] to public Downloads under this
  /// name when finished. Null for uploads.
  final String? publishName;

  int? total; // filled in asynchronously once the size is known
  int transferred = 0;
  late final StreamSubscription<int> sub;

  /// Last time the notification was refreshed, to throttle updates (a fast
  /// transfer emits every 256 KB — far too often to re-post the notification).
  DateTime lastNotifAt = DateTime.fromMillisecondsSinceEpoch(0);

  TransferInfo({
    required this.label,
    required this.isUpload,
    required this.localPath,
    this.publishName,
    this.total,
  });
}

class BackgroundSession {
  final String sessionId;
  final String displayName;
  final String username;
  int port;
  final List<SSHKeyPair> identities;
  final ConnectionType connectionType;
  final TabKind kind;

  /// Connection parameters needed for reconnection.
  final String? endpointId;
  final List<String> relayUrls;
  final List<String> extraRelayUrls;
  final int? maxRemoteNatTraversalAddresses;

  /// Direct SSH connection parameters.
  final String? sshHost;
  final int? sshPort;

  SSHClient? _client;
  SSHSession? _session;
  Pty? _pty;

  /// File-manager backend (SFTP for iroh/ssh, local fs for local), set when
  /// [kind] is [TabKind.files]. Null for terminal sessions.
  RemoteFs? _fs;

  /// In-flight SFTP transfers keyed by requestId, so a cancel can abort them.
  final Map<String, TransferInfo> _activeTransfers = {};

  /// True if this session owns the transfer with [requestId] (for routing a
  /// notification Cancel tap to the right session).
  bool hasTransfer(String requestId) => _activeTransfers.containsKey(requestId);

  /// Native per-transfer progress notifications (set by the service). All
  /// transfer UI lives here — nothing crosses to the UI isolate.
  TransferNotifications? notifications;

  SessionState state = SessionState.connecting;
  final TerminalReplayBuffer replayBuffer = TerminalReplayBuffer();
  bool uiAttached = false;

  /// Callback to send events to the UI (set by the service).
  void Function(String data)? onSendToUi;

  /// Called when the session has ended and should be removed.
  void Function()? onSessionEnded;

  /// Pending auth prompt completer — waits for UI to respond.
  Completer<String>? _authCompleter;

  /// Queued auth prompts waiting for UI to attach.
  final List<_PendingAuthPrompt> _pendingAuthPrompts = [];

  // Stdout/stderr batching
  static const _batchDuration = Duration(milliseconds: 2);
  final _stdoutBuffer = BytesBuilder(copy: false);
  Timer? _stdoutFlushTimer;
  final _stderrBuffer = BytesBuilder(copy: false);
  Timer? _stderrFlushTimer;

  StreamSubscription? _ptyOutputSubscription;

  BackgroundSession({
    required this.sessionId,
    required this.displayName,
    required this.username,
    required this.port,
    required this.identities,
    this.connectionType = ConnectionType.iroh,
    this.kind = TabKind.terminal,
    this.endpointId,
    this.relayUrls = const [],
    this.extraRelayUrls = const [],
    this.maxRemoteNatTraversalAddresses,
    this.sshHost,
    this.sshPort,
  });

  Future<void> connect() async {
    switch (connectionType) {
      case ConnectionType.iroh:
      case ConnectionType.ssh:
        await _connectSsh();
      case ConnectionType.local:
        if (kind == TabKind.files) {
          _connectLocalFiles();
        } else {
          _connectLocalShell();
        }
    }
  }

  Future<void> _connectSsh() async {
    state = SessionState.connecting;
    final connectHost =
        connectionType == ConnectionType.ssh ? sshHost! : 'localhost';
    final connectPort =
        connectionType == ConnectionType.ssh ? (sshPort ?? 22) : port;
    _sendStatus('Connecting to $connectHost:$connectPort...');

    try {
      final socket = await SSHSocket.connect(connectHost, connectPort);

      _client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: () async {
          return await _requestAuth('Password: ', echo: false);
        },
        onUserInfoRequest: (request) async {
          if (request.prompts.isEmpty) return [];
          final responses = <String>[];
          for (final prompt in request.prompts) {
            final response =
                await _requestAuth(prompt.promptText, echo: prompt.echo);
            responses.add(response);
          }
          return responses;
        },
        onUserauthBanner: (banner) {
          final bytes = utf8.encode(banner.replaceAll('\n', '\r\n'));
          replayBuffer.write(bytes);
          _forwardOutput(bytes);
        },
      );

      _sendStatus('Authenticating...');

      if (kind == TabKind.files) {
        // Open an SFTP channel over the same authenticated connection instead
        // of a shell. ShellReadyEvent doubles as the "fs ready" signal.
        _fs = SftpFs(await _client!.sftp());
        state = SessionState.connected;
        _sendShellReady();
      } else {
        _session = await _client!.shell(
          pty: SSHPtyConfig(width: 80, height: 24),
        );

        state = SessionState.connected;
        _sendShellReady();

        _session!.stdout.listen((data) {
          _stdoutBuffer.add(data);
          _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
        });

        _session!.stderr.listen((data) {
          _stderrBuffer.add(data);
          _stderrFlushTimer ??= Timer(_batchDuration, _flushStderr);
        });

        _session!.done.then((_) {
          disconnect(reason: 'Session ended');
        });
      }
    } catch (e) {
      final errorMsg = '\r\nError: $e\r\n';
      final bytes = utf8.encode(errorMsg);
      replayBuffer.write(bytes);
      _forwardOutput(bytes);
      state = SessionState.disconnected;
      _sendError(e.toString());
    }
  }

  void _connectLocalShell() {
    state = SessionState.connecting;
    _sendStatus('Starting local shell...');

    try {
      final shell = Platform.environment['SHELL'] ?? 'sh';
      _pty = Pty.start(shell, columns: 80, rows: 24);

      state = SessionState.connected;
      _sendShellReady();

      _ptyOutputSubscription = _pty!.output.listen((data) {
        _stdoutBuffer.add(data);
        _stdoutFlushTimer ??= Timer(_batchDuration, _flushStdout);
      });

      _pty!.exitCode.then((_) {
        disconnect(reason: 'Shell exited');
      });
    } catch (e) {
      final errorMsg = '\r\nError: $e\r\n';
      final bytes = utf8.encode(errorMsg);
      replayBuffer.write(bytes);
      _forwardOutput(bytes);
      state = SessionState.disconnected;
      _sendError(e.toString());
    }
  }

  void _connectLocalFiles() {
    state = SessionState.connecting;
    _sendStatus('Opening local files...');
    _fs = LocalFs();
    state = SessionState.connected;
    _sendShellReady();
  }

  /// Test-only: attach a fake [RemoteFs] and mark the session connected, so the
  /// SFTP/transfer orchestration ([handleSftp], notifications, publish, cancel)
  /// can be exercised without a real connection.
  @visibleForTesting
  void debugAttachFs(RemoteFs fs) {
    _fs = fs;
    state = SessionState.connected;
  }

  // =========================================================================
  // SFTP / file-manager command handling
  // =========================================================================

  /// Dispatch an SFTP command (routed here by the service) to [_fs] and stream
  /// results/progress/errors back to the UI, correlated by requestId.
  Future<void> handleSftp(ServiceCommand command) async {
    switch (command) {
      case SftpListCommand():
        await _sftpGuarded(command.requestId, () async {
          final entries = await _fs!.list(command.path);
          _sendSftp(SftpListResultEvent(
            sessionId: sessionId,
            requestId: command.requestId,
            entries: entries,
          ));
        });
      case SftpStatCommand():
        await _sftpGuarded(command.requestId, () async {
          final entry = await _fs!.stat(command.path);
          _sendSftp(SftpStatResultEvent(
            sessionId: sessionId,
            requestId: command.requestId,
            entry: entry,
          ));
        });
      case SftpMkdirCommand():
        await _sftpOk(command.requestId, () => _fs!.mkdir(command.path));
      case SftpRenameCommand():
        await _sftpOk(
            command.requestId, () => _fs!.rename(command.from, command.to));
      case SftpRemoveCommand():
        await _sftpOk(command.requestId,
            () => _fs!.remove(command.path, recursive: command.recursive));
      case SftpDownloadCommand():
        // Register the transfer synchronously so a fast cancel can find it,
        // then resolve the size for the notification's progress % in parallel.
        _sftpTransfer(
          command.requestId,
          label: p.posix.basename(command.remotePath),
          isUpload: false,
          localPath: command.localPath,
          publishName: command.publishName,
          open: () => _fs!.download(command.remotePath, command.localPath),
        );
        _resolveTotal(
            command.requestId, () => _statSizeQuietly(command.remotePath));
      case SftpUploadCommand():
        await _sftpUpload(command);
      case SftpInitialDirCommand():
        await _sftpGuarded(command.requestId, () async {
          final dir = await _fs!.initialDir();
          _sendSftp(SftpPathResultEvent(
            sessionId: sessionId,
            requestId: command.requestId,
            path: dir,
          ));
        });
      case SftpCancelCommand():
        await cancelTransfer(command.requestId);
      default:
        break;
    }
  }

  /// Start an upload, first choosing a non-clobbering remote name: uploading a
  /// file whose name already exists in the target directory creates
  /// `name (1).ext`, `name (2).ext`, … rather than overwriting it. The
  /// notification label reflects the final name.
  ///
  /// Resolving the name needs an SFTP `listdir` round trip, so this awaits
  /// before registering the transfer — safe because a Cancel can only come from
  /// the transfer's notification, which doesn't exist until [_sftpTransfer] runs.
  Future<void> _sftpUpload(SftpUploadCommand command) async {
    final fs = _fs;
    if (fs == null) {
      _sendSftp(SftpErrorEvent(
        sessionId: sessionId,
        requestId: command.requestId,
        message: 'File manager not ready',
      ));
      return;
    }
    final remotePath = await resolveUploadTarget(
      dir: p.posix.dirname(command.remotePath),
      name: p.posix.basename(command.remotePath),
      join: fs.join,
      listNames: (dir) async => (await fs.list(dir)).map((e) => e.name).toList(),
    );
    _sftpTransfer(
      command.requestId,
      label: p.posix.basename(remotePath),
      isUpload: true,
      localPath: command.localPath,
      open: () => fs.upload(command.localPath, remotePath),
    );
    _resolveTotal(
        command.requestId, () => _fileLengthQuietly(command.localPath));
  }

  /// Abort an in-flight transfer (from the notification's Cancel action) and
  /// remove its notification. For a download the partial temp file is deleted.
  Future<void> cancelTransfer(String requestId) async {
    final info = _activeTransfers.remove(requestId);
    if (info == null) return;
    await info.sub.cancel();
    if (!info.isUpload) await _deleteQuietly(info.localPath);
    await notifications?.cancel(requestId);
  }

  /// Abort every in-flight transfer (on disconnect/reconnect): cancel the
  /// subscription, drop any partial download temp file, and clear its notification.
  Future<void> _abortAllTransfers() async {
    for (final entry in _activeTransfers.entries) {
      await entry.value.sub.cancel();
      if (!entry.value.isUpload) await _deleteQuietly(entry.value.localPath);
      await notifications?.cancel(entry.key);
    }
    _activeTransfers.clear();
  }

  /// Resolve a transfer's total size (for the notification %) without blocking
  /// its start. No-op if the transfer was already cancelled/finished.
  Future<void> _resolveTotal(
      String requestId, Future<int?> Function() get) async {
    final total = await get();
    final info = _activeTransfers[requestId];
    if (info != null && total != null) {
      info.total = total;
      _showProgress(requestId, info);
    }
  }

  Future<int?> _statSizeQuietly(String path) async {
    try {
      return (await _fs?.stat(path))?.size;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _fileLengthQuietly(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  void _sendSftp(ServiceEvent event) {
    if (onSendToUi != null) onSendToUi!(event.encode());
  }

  Future<void> _sftpGuarded(
      String requestId, Future<void> Function() op) async {
    if (_fs == null) {
      _sendSftp(SftpErrorEvent(
        sessionId: sessionId,
        requestId: requestId,
        message: 'File manager not ready',
      ));
      return;
    }
    try {
      await op();
    } catch (e) {
      _sendSftp(SftpErrorEvent(
        sessionId: sessionId,
        requestId: requestId,
        message: e.toString(),
      ));
    }
  }

  Future<void> _sftpOk(String requestId, Future<void> Function() op) async {
    await _sftpGuarded(requestId, () async {
      await op();
      _sendSftp(SftpOkEvent(sessionId: sessionId, requestId: requestId));
    });
  }

  void _sftpTransfer(
    String requestId, {
    required String label,
    required bool isUpload,
    required String localPath,
    String? publishName,
    required Stream<int> Function() open,
  }) {
    if (_fs == null) {
      _sendSftp(SftpErrorEvent(
        sessionId: sessionId,
        requestId: requestId,
        message: 'File manager not ready',
      ));
      return;
    }
    final info = TransferInfo(
      label: label,
      isUpload: isUpload,
      localPath: localPath,
      publishName: publishName,
    );
    info.sub = open().listen(
      (transferred) {
        // Ignore late events after a cancel removed the transfer, so its
        // notification isn't re-created.
        if (!_activeTransfers.containsKey(requestId)) return;
        info.transferred = transferred;
        // Throttle notification refreshes — posting on every 256 KB chunk
        // floods the platform/main thread (NotificationManager.notify) and ANRs.
        final now = DateTime.now();
        if (now.difference(info.lastNotifAt) >=
            const Duration(milliseconds: 400)) {
          info.lastNotifAt = now;
          _showProgress(requestId, info);
        }
      },
      onError: (e) {
        _activeTransfers.remove(requestId);
        if (!isUpload) _deleteQuietly(localPath);
        notifications?.show(
          requestId: requestId,
          title: label,
          text: 'Failed: $e',
          isUpload: isUpload,
          ongoing: false,
          showCancel: false,
        );
      },
      onDone: () {
        _activeTransfers.remove(requestId);
        _finishTransfer(requestId, info);
      },
      cancelOnError: true,
    );
    _activeTransfers[requestId] = info;
    _showProgress(requestId, info);
  }

  void _showProgress(String requestId, TransferInfo info) {
    notifications?.show(
      requestId: requestId,
      title: info.label,
      text: transferText(info.transferred, info.total),
      isUpload: info.isUpload,
      max: info.total ?? 0,
      progress: info.transferred,
      indeterminate: info.total == null,
      ongoing: true,
      showCancel: true,
    );
  }

  /// Finalize a completed transfer: publish a download to public Downloads,
  /// show the final notification, and tell the UI to refresh its listing.
  Future<void> _finishTransfer(String requestId, TransferInfo info) async {
    String resultText;
    String? openUri;
    if (info.isUpload) {
      resultText = 'Uploaded';
    } else if (info.publishName != null) {
      final saved = await _publishDownload(info);
      if (saved != null) {
        resultText = 'Saved to ${saved.displayPath}';
        openUri = saved.uri; // tapping the finished notification opens the file
      } else {
        resultText = 'Saved';
      }
    } else {
      resultText = 'Saved';
    }
    await notifications?.show(
      requestId: requestId,
      title: info.label,
      text: resultText,
      isUpload: info.isUpload,
      ongoing: false,
      showCancel: false,
      openUri: openUri,
    );
    // Let the tab refresh its listing (e.g. show a just-uploaded file).
    _sendSftp(SftpDoneEvent(sessionId: sessionId, requestId: requestId));
  }

  /// Publish a finished download (temp [TransferInfo.localPath]) into the
  /// device's public Downloads via MediaStore, then remove the temp file.
  /// Returns the [SavedDownload] (content URI + display path), or null on failure.
  Future<SavedDownload?> _publishDownload(TransferInfo info) async {
    try {
      final saved = await MediaStore.saveToDownloads(
        sourcePath: info.localPath,
        displayName: info.publishName!,
      );
      await _deleteQuietly(info.localPath);
      return saved;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  void _flushStdout() {
    _stdoutFlushTimer = null;
    final bytes = _stdoutBuffer.takeBytes();
    replayBuffer.write(bytes);
    _forwardOutput(bytes);
  }

  void _flushStderr() {
    _stderrFlushTimer = null;
    final bytes = _stderrBuffer.takeBytes();
    replayBuffer.write(bytes);
    _forwardOutput(bytes);
  }

  void _forwardOutput(List<int> bytes) {
    if (uiAttached && onSendToUi != null) {
      final encoded = base64Encode(bytes);
      onSendToUi!('{"type":"output","sessionId":"$sessionId","data":"$encoded"}');
    }
  }

  void _sendStatus(String message) {
    final bytes = utf8.encode('$message\r\n');
    replayBuffer.write(bytes);
    _forwardOutput(bytes);
  }

  void _sendError(String message) {
    if (onSendToUi != null) {
      onSendToUi!(ErrorEvent(
        sessionId: sessionId,
        message: message,
      ).encode());
    }
  }

  void _sendShellReady() {
    if (onSendToUi != null) {
      onSendToUi!(ShellReadyEvent(sessionId: sessionId).encode());
    }
  }

  Future<String> _requestAuth(String prompt, {required bool echo}) async {
    if (uiAttached && onSendToUi != null) {
      _authCompleter = Completer<String>();
      onSendToUi!(
        '{"type":"auth_prompt","sessionId":"$sessionId",'
        '"prompt":${jsonEncode(prompt)},"echo":$echo}',
      );
      return _authCompleter!.future;
    } else {
      // Queue the prompt until UI attaches
      final completer = Completer<String>();
      _pendingAuthPrompts.add(_PendingAuthPrompt(
        prompt: prompt,
        echo: echo,
        completer: completer,
      ));
      return completer.future;
    }
  }

  void handleAuthResponse(String response) {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(response);
      _authCompleter = null;
    }
  }

  void handleInput(Uint8List data) {
    if (connectionType == ConnectionType.local) {
      _pty?.write(data);
    } else {
      _session?.write(data);
    }
  }

  void handleResize(int width, int height) {
    if (connectionType == ConnectionType.local) {
      _pty?.resize(height, width);
    } else {
      _session?.resizeTerminal(width, height);
    }
  }

  void onAttach() {
    uiAttached = true;

    if (state == SessionState.connected) {
      _sendShellReady();
    }

    // Send any pending auth prompts
    if (_pendingAuthPrompts.isNotEmpty && onSendToUi != null) {
      final pending = _pendingAuthPrompts.removeAt(0);
      _authCompleter = pending.completer;
      onSendToUi!(
        '{"type":"auth_prompt","sessionId":"$sessionId",'
        '"prompt":${jsonEncode(pending.prompt)},"echo":${pending.echo}}',
      );
    }
  }

  void onDetach() {
    uiAttached = false;
  }

  Future<void> reconnect() async {
    // Clean up old connection
    _ptyOutputSubscription?.cancel();
    _ptyOutputSubscription = null;
    _pty?.kill();
    _pty = null;
    await _abortAllTransfers();
    await _fs?.close();
    _fs = null;
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    _stdoutFlushTimer?.cancel();
    _stderrFlushTimer?.cancel();
    _authCompleter?.complete('');
    _authCompleter = null;
    for (final pending in _pendingAuthPrompts) {
      pending.completer.complete('');
    }
    _pendingAuthPrompts.clear();

    if (connectionType == ConnectionType.iroh) {
      // Clean up old iroh tunnel
      try {
        await disconnectIroh(port: port);
      } catch (_) {}

      // Establish new iroh tunnel
      _sendStatus('Reconnecting...');
      port = await connectIroh(
        endpointId: endpointId!,
        relayUrls: relayUrls,
        extraRelayUrls: extraRelayUrls,
        maxRemoteNatTraversalAddresses: maxRemoteNatTraversalAddresses,
      );
    } else {
      _sendStatus('Reconnecting...');
    }

    // Start connection
    await connect();
  }

  Future<void> disconnect({String reason = 'Disconnected'}) async {
    if (state == SessionState.disconnected) return;
    state = SessionState.disconnected;
    _stdoutFlushTimer?.cancel();
    _stderrFlushTimer?.cancel();
    _ptyOutputSubscription?.cancel();
    _ptyOutputSubscription = null;
    _pty?.kill();
    _pty = null;
    await _abortAllTransfers();
    await _fs?.close();
    _fs = null;
    _session?.close();
    _client?.close();
    if (connectionType == ConnectionType.iroh) {
      try {
        await disconnectIroh(port: port);
      } catch (_) {
        // Port may already be cleaned up
      }
    }
    if (uiAttached && onSendToUi != null) {
      onSendToUi!(
        '{"type":"disconnected","sessionId":"$sessionId",'
        '"reason":${jsonEncode(reason)}}',
      );
    }
    // Complete any pending auth with empty string to unblock
    _authCompleter?.complete('');
    for (final pending in _pendingAuthPrompts) {
      pending.completer.complete('');
    }
    _pendingAuthPrompts.clear();
    onSessionEnded?.call();
  }
}

class _PendingAuthPrompt {
  final String prompt;
  final bool echo;
  final Completer<String> completer;

  _PendingAuthPrompt({
    required this.prompt,
    required this.echo,
    required this.completer,
  });
}
