import 'dart:async';

import 'package:iroh_ssh_app/models/fs_entry.dart';
import 'package:iroh_ssh_app/services/fs/remote_fs.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:path/path.dart' as p;

/// An error surfaced by a [RemoteFs] operation, carrying a human-readable
/// message (e.g. an SFTP "permission denied"). Its [toString] is just the
/// message so the UI can show it directly.
class RemoteFsException implements Exception {
  final String message;
  RemoteFsException(this.message);

  @override
  String toString() => message;
}

/// UI-side [RemoteFs] that proxies every call to the background service over
/// the foreground-task message channel, correlating responses by requestId.
/// Used on Android; on desktop the tab talks to a real [SftpFs]/[LocalFs].
///
/// Android device paths and SFTP paths are both POSIX, so path math is posix.
class IpcRemoteFs implements RemoteFs {
  final String sessionId;
  final void Function(String encodedCommand) send;

  int _counter = 0;
  final Map<String, Completer<dynamic>> _pending = {};
  final Map<String, StreamController<int>> _transfers = {};
  bool _closed = false;

  IpcRemoteFs({required this.sessionId, required this.send});

  String _nextId() => '${sessionId}_${_counter++}';

  @override
  String join(String dir, String name) => p.posix.join(dir, name);

  @override
  String parentOf(String path) {
    final parent = p.posix.dirname(path);
    return parent.isEmpty ? '/' : parent;
  }

  /// Route a service event to the matching pending request/transfer. The tab
  /// calls this for every [ServiceEvent] it receives.
  void handleEvent(ServiceEvent event) {
    switch (event) {
      case SftpListResultEvent() when event.sessionId == sessionId:
        _complete(event.requestId, event.entries);
      case SftpStatResultEvent() when event.sessionId == sessionId:
        _complete(event.requestId, event.entry);
      case SftpPathResultEvent() when event.sessionId == sessionId:
        _complete(event.requestId, event.path);
      case SftpOkEvent() when event.sessionId == sessionId:
        _complete(event.requestId, null);
      case SftpProgressEvent() when event.sessionId == sessionId:
        _transfers[event.requestId]?.add(event.transferred);
      case SftpDoneEvent() when event.sessionId == sessionId:
        _transfers.remove(event.requestId)?.close();
      case SftpErrorEvent() when event.sessionId == sessionId:
        _fail(event.requestId, RemoteFsException(event.message));
      default:
        break;
    }
  }

  void _complete(String requestId, dynamic value) {
    final c = _pending.remove(requestId);
    if (c != null && !c.isCompleted) c.complete(value);
  }

  void _fail(String requestId, Object error) {
    final c = _pending.remove(requestId);
    if (c != null && !c.isCompleted) c.completeError(error);
    final t = _transfers.remove(requestId);
    if (t != null && !t.isClosed) {
      t.addError(error);
      t.close();
    }
  }

  Future<T> _request<T>(String requestId, ServiceCommand command) {
    final completer = Completer<T>();
    _pending[requestId] = completer;
    send(command.encode());
    return completer.future;
  }

  @override
  Future<String> initialDir() {
    final id = _nextId();
    return _request<String>(
        id, SftpInitialDirCommand(sessionId: sessionId, requestId: id));
  }

  @override
  Future<List<FsEntry>> list(String path) {
    final id = _nextId();
    return _request<List<FsEntry>>(
        id, SftpListCommand(sessionId: sessionId, requestId: id, path: path));
  }

  @override
  Future<FsEntry> stat(String path, {bool followLink = true}) {
    final id = _nextId();
    return _request<FsEntry>(
        id, SftpStatCommand(sessionId: sessionId, requestId: id, path: path));
  }

  @override
  Future<void> mkdir(String path) {
    final id = _nextId();
    return _request<void>(
        id, SftpMkdirCommand(sessionId: sessionId, requestId: id, path: path));
  }

  @override
  Future<void> rename(String from, String to) {
    final id = _nextId();
    return _request<void>(
        id,
        SftpRenameCommand(
            sessionId: sessionId, requestId: id, from: from, to: to));
  }

  @override
  Future<void> remove(String path, {bool recursive = false}) {
    final id = _nextId();
    return _request<void>(
        id,
        SftpRemoveCommand(
            sessionId: sessionId,
            requestId: id,
            path: path,
            recursive: recursive));
  }

  @override
  Stream<int> download(String remotePath, String localPath) {
    final id = _nextId();
    return _transfer(
        id,
        SftpDownloadCommand(
            sessionId: sessionId,
            requestId: id,
            remotePath: remotePath,
            localPath: localPath));
  }

  @override
  Stream<int> upload(String localPath, String remotePath) {
    final id = _nextId();
    return _transfer(
        id,
        SftpUploadCommand(
            sessionId: sessionId,
            requestId: id,
            localPath: localPath,
            remotePath: remotePath));
  }

  Stream<int> _transfer(String requestId, ServiceCommand command) {
    late StreamController<int> controller;
    controller = StreamController<int>(
      onListen: () => send(command.encode()),
      onCancel: () {
        // Tell the service to abort the in-flight transfer.
        if (!_closed) {
          send(SftpCancelCommand(sessionId: sessionId, requestId: requestId)
              .encode());
        }
        _transfers.remove(requestId);
      },
    );
    _transfers[requestId] = controller;
    return controller.stream;
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(RemoteFsException('Disconnected'));
    }
    _pending.clear();
    for (final t in _transfers.values) {
      if (!t.isClosed) await t.close();
    }
    _transfers.clear();
  }
}
