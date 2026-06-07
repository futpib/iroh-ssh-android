import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:iroh_ssh_app/models/connection_type.dart';
import 'package:iroh_ssh_app/models/tab_kind.dart';
import 'package:iroh_ssh_app/screens/qr_scanner_screen.dart';
import 'package:iroh_ssh_app/services/connection_storage.dart';
import 'package:iroh_ssh_app/services/key_storage.dart';
import 'package:iroh_ssh_app/services/session_messages.dart';
import 'package:iroh_ssh_app/services/session_service.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/src/rust/api/simple.dart';
import 'package:iroh_ssh_app/screens/settings_screen.dart';
import 'package:iroh_ssh_app/models/ssh_session_info.dart';
import 'package:iroh_ssh_app/screens/sessions_screen.dart';
import 'package:iroh_ssh_app/widgets/network_settings_editor.dart';

class ConnectScreen extends StatefulWidget {
  final bool returnResult;
  final List<SshSessionInfo> existingSessions;

  const ConnectScreen({
    super.key,
    this.returnResult = false,
    this.existingSessions = const [],
  });

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _targetController = TextEditingController();
  ConnectionType _connectionType = ConnectionType.iroh;
  TabKind _tabKind = TabKind.terminal;
  bool _overrideRelays = false;
  bool _useDefaultRelays = true;
  List<String> _customRelayUrls = [];
  int? _maxRemoteNatTraversalAddresses;
  bool _connecting = false;
  String? _error;
  List<SavedConnection> _savedConnections = [];

  @override
  void initState() {
    super.initState();
    _loadConnections();
    _initConnectionType();
  }

  Future<void> _initConnectionType() async {
    final type = await _computeDefaultConnectionType();
    if (mounted) {
      setState(() => _connectionType = type);
    }
  }

  Future<ConnectionType> _computeDefaultConnectionType() async {
    final sessions = widget.existingSessions;
    if (sessions.isNotEmpty) {
      final counts = <ConnectionType, int>{};
      for (final s in sessions) {
        counts[s.connectionType] = (counts[s.connectionType] ?? 0) + 1;
      }
      final threshold = (sessions.length * 2 / 3).ceil();
      for (final entry in counts.entries) {
        if (entry.value >= threshold) {
          return entry.key;
        }
      }
    }
    final settings = await SettingsStorage.instance.load();
    if (settings.lastConnectionType != null) {
      return ConnectionType.values
              .where((e) => e.name == settings.lastConnectionType)
              .firstOrNull ??
          ConnectionType.iroh;
    }
    return ConnectionType.iroh;
  }

  Future<void> _persistLastConnectionType(ConnectionType type) async {
    final settings = await SettingsStorage.instance.load();
    await SettingsStorage.instance.save(AppSettings(
      useDefaultRelays: settings.useDefaultRelays,
      customRelayUrls: settings.customRelayUrls,
      maxRemoteNatTraversalAddresses: settings.maxRemoteNatTraversalAddresses,
      terminalFontSize: settings.terminalFontSize,
      terminalTheme: settings.terminalTheme,
      barPosition: settings.barPosition,
      tabViewStyle: settings.tabViewStyle,
      lastConnectionType: type.name,
    ));
  }

  Future<void> _loadConnections() async {
    final connections = await ConnectionStorage.instance.list();
    if (mounted) {
      setState(() => _savedConnections = connections);
    }
  }

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _ensureServiceStarted() async {
    if (!Platform.isAndroid) return;

    final running = await FlutterForegroundTask.isRunningService;
    if (!running) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'iroh_ssh_foreground',
          channelName: 'SSH Session',
          channelDescription: 'Keeps SSH sessions alive in the background',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      await FlutterForegroundTask.requestNotificationPermission();
      await FlutterForegroundTask.startService(
        // dataSync covers the file transfers; specialUse keeps SSH sessions alive.
        serviceTypes: const [
          ForegroundServiceTypes.dataSync,
          ForegroundServiceTypes.specialUse,
        ],
        notificationTitle: 'Iroh SSH',
        notificationText: 'Connecting...',
        notificationButtons: [
          NotificationButton(id: 'disconnect_all', text: 'Disconnect all'),
        ],
        callback: startCallback,
      );
    }
  }

  Future<void> _connectTo(String target,
      {ConnectionType connectionType = ConnectionType.iroh,
      TabKind kind = TabKind.terminal,
      bool overrideRelays = false,
      bool useDefaultRelays = true,
      List<String> customRelayUrls = const [],
      int? maxRemoteNatTraversalAddresses}) async {
    final String username;
    final String? endpointId;
    final String? sshHost;
    final int? sshPort;

    switch (connectionType) {
      case ConnectionType.iroh:
        if (!target.contains('@')) {
          setState(() => _error = 'Expected format: user@endpoint_id');
          return;
        }
        username = target.split('@').first;
        endpointId = target.split('@').skip(1).join('@');
        sshHost = null;
        sshPort = null;

      case ConnectionType.ssh:
        if (!target.contains('@')) {
          setState(() => _error = 'Expected format: user@host or user@host:port');
          return;
        }
        username = target.split('@').first;
        endpointId = null;
        final afterAt = target.split('@').skip(1).join('@');
        if (afterAt.contains(':')) {
          sshHost = afterAt.split(':').first;
          sshPort = int.tryParse(afterAt.split(':').last) ?? 22;
        } else {
          sshHost = afterAt;
          sshPort = 22;
        }

      case ConnectionType.local:
        username = '';
        endpointId = null;
        sshHost = null;
        sshPort = null;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });

    _persistLastConnectionType(connectionType);

    try {
      final keys = await KeyStorage.instance.listKeys();
      final globalSettings = await SettingsStorage.instance.load();

      final effectiveUseDefaultRelays =
          overrideRelays ? useDefaultRelays : globalSettings.useDefaultRelays;
      final effectiveCustomRelayUrls =
          overrideRelays ? customRelayUrls : globalSettings.customRelayUrls;

      final List<String> relayUrls;
      final List<String> extraRelayUrls;
      if (effectiveUseDefaultRelays) {
        relayUrls = [];
        extraRelayUrls = effectiveCustomRelayUrls;
      } else {
        relayUrls = effectiveCustomRelayUrls;
        extraRelayUrls = [];
      }

      final effectiveMaxNat = overrideRelays
          ? maxRemoteNatTraversalAddresses
          : globalSettings.maxRemoteNatTraversalAddresses;

      final displayName = connectionType == ConnectionType.local
          ? 'Local'
          : target;

      if (Platform.isAndroid) {
        await _ensureServiceStarted();

        // Send connect command via IPC and wait for connected event
        final completer = Completer<SshSessionInfo>();

        void onData(Object data) {
          if (data is! String) return;
          try {
            final event = ServiceEvent.decode(data);
            if (event is ConnectedEvent) {
              FlutterForegroundTask.removeTaskDataCallback(onData);
              if (!completer.isCompleted) {
                completer.complete(SshSessionInfo(
                  sessionId: event.sessionId,
                  host: event.host ?? (connectionType == ConnectionType.ssh ? sshHost! : 'localhost'),
                  port: event.port,
                  username: event.username,
                  displayName: event.displayName,
                  connectionType: connectionType,
                  kind: kind,
                ));
              }
            } else if (event is ErrorEvent) {
              FlutterForegroundTask.removeTaskDataCallback(onData);
              if (!completer.isCompleted) {
                completer.completeError(Exception(event.message));
              }
            }
          } catch (_) {}
        }

        FlutterForegroundTask.addTaskDataCallback(onData);
        FlutterForegroundTask.sendDataToTask(ConnectCommand(
          connectionType: connectionType,
          kind: kind,
          endpointId: endpointId,
          username: username,
          displayName: displayName,
          keyNames: keys.map((k) => k.name).toList(),
          relayUrls: relayUrls,
          extraRelayUrls: extraRelayUrls,
          maxRemoteNatTraversalAddresses: effectiveMaxNat,
          host: sshHost,
          sshPort: sshPort,
        ).encode());

        final sessionInfo = await completer.future;

        if (connectionType != ConnectionType.local) {
          await ConnectionStorage.instance.save(SavedConnection(
            target: target,
            connectionType: connectionType,
            overrideRelays: overrideRelays,
            useDefaultRelays: useDefaultRelays,
            customRelayUrls: customRelayUrls,
            maxRemoteNatTraversalAddresses: maxRemoteNatTraversalAddresses,
          ));
          await _loadConnections();
        }

        if (!mounted) return;

        if (widget.returnResult) {
          Navigator.of(context).pop(sessionInfo);
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  SessionsScreen(existingSessions: [sessionInfo]),
            ),
          );
        }
      } else {
        // Non-Android: use direct connection (no foreground service)
        final int port;
        if (connectionType == ConnectionType.iroh) {
          port = await _connectDirect(
            endpointId: endpointId!,
            relayUrls: relayUrls,
            extraRelayUrls: extraRelayUrls,
            maxRemoteNatTraversalAddresses: effectiveMaxNat,
          );
        } else if (connectionType == ConnectionType.ssh) {
          port = sshPort ?? 22;
        } else {
          port = 0;
        }

        if (connectionType != ConnectionType.local) {
          await ConnectionStorage.instance.save(SavedConnection(
            target: target,
            connectionType: connectionType,
            overrideRelays: overrideRelays,
            useDefaultRelays: useDefaultRelays,
            customRelayUrls: customRelayUrls,
            maxRemoteNatTraversalAddresses: maxRemoteNatTraversalAddresses,
          ));
          await _loadConnections();
        }

        if (!mounted) return;

        final host = connectionType == ConnectionType.ssh
            ? sshHost!
            : 'localhost';

        final sessionInfo = SshSessionInfo(
          sessionId: 'local_${DateTime.now().millisecondsSinceEpoch}',
          host: host,
          port: port,
          username: username,
          keyNames: keys.map((k) => k.name).toList(),
          displayName: displayName,
          connectionType: connectionType,
          kind: kind,
        );

        if (widget.returnResult) {
          Navigator.of(context).pop(sessionInfo);
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  SessionsScreen(existingSessions: [sessionInfo]),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  Future<int> _connectDirect({
    required String endpointId,
    required List<String> relayUrls,
    required List<String> extraRelayUrls,
    int? maxRemoteNatTraversalAddresses,
  }) async {
    return await connectIroh(
      endpointId: endpointId,
      relayUrls: relayUrls,
      extraRelayUrls: extraRelayUrls,
      maxRemoteNatTraversalAddresses: maxRemoteNatTraversalAddresses,
    );
  }

  Future<void> _connect() async {
    if (_connectionType == ConnectionType.local) {
      await _connectTo('',
          connectionType: ConnectionType.local, kind: _tabKind);
      return;
    }

    final raw = _targetController.text.trim();
    if (raw.isEmpty) {
      final hint = _connectionType == ConnectionType.iroh
          ? 'Paste a target like user@endpoint_id'
          : 'Enter a target like user@host or user@host:port';
      setState(() => _error = hint);
      return;
    }
    await _connectTo(raw,
        connectionType: _connectionType,
        kind: _tabKind,
        overrideRelays: _overrideRelays,
        useDefaultRelays: _useDefaultRelays,
        customRelayUrls: _customRelayUrls,
        maxRemoteNatTraversalAddresses: _maxRemoteNatTraversalAddresses);
  }

  Future<void> _deleteConnection(SavedConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Connection'),
        content: Text('Remove "${connection.target}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ConnectionStorage.instance.delete(connection.target);
      await _loadConnections();
    }
  }

  void _onSavedConnectionTap(SavedConnection conn) {
    setState(() {
      _targetController.text = conn.target;
      _connectionType = conn.connectionType;
      _overrideRelays = conn.overrideRelays;
      _useDefaultRelays = conn.useDefaultRelays;
      _customRelayUrls = List.of(conn.customRelayUrls);
      _maxRemoteNatTraversalAddresses = conn.maxRemoteNatTraversalAddresses;
    });
    _connectTo(conn.target,
        connectionType: conn.connectionType,
        kind: _tabKind,
        overrideRelays: conn.overrideRelays,
        useDefaultRelays: conn.useDefaultRelays,
        customRelayUrls: conn.customRelayUrls,
        maxRemoteNatTraversalAddresses: conn.maxRemoteNatTraversalAddresses);
  }

  IconData _iconForConnectionType(ConnectionType type) => switch (type) {
        ConnectionType.iroh => Icons.cloud,
        ConnectionType.ssh => Icons.computer,
        ConnectionType.local => Icons.terminal,
      };

  String _subtitleForConnection(SavedConnection conn) {
    switch (conn.connectionType) {
      case ConnectionType.iroh:
        return conn.endpointId;
      case ConnectionType.ssh:
        final port = conn.sshPort;
        return port != 22 ? '${conn.sshHost}:$port' : conn.sshHost;
      case ConnectionType.local:
        return 'Local';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Iroh SSH'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<ConnectionType>(
                  segments: ConnectionType.values.map((type) {
                    return ButtonSegment<ConnectionType>(
                      value: type,
                      label: Text(type.label),
                      icon: Icon(_iconForConnectionType(type)),
                    );
                  }).toList(),
                  selected: {_connectionType},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _connectionType = selected.first;
                      _error = null;
                    });
                  },
                ),
                const SizedBox(height: 12),
                SegmentedButton<TabKind>(
                  segments: TabKind.values.map((kind) {
                    return ButtonSegment<TabKind>(
                      value: kind,
                      label: Text(kind.label),
                      icon: Icon(kind == TabKind.terminal
                          ? Icons.terminal
                          : Icons.folder_outlined),
                    );
                  }).toList(),
                  selected: {_tabKind},
                  onSelectionChanged: (selected) {
                    setState(() => _tabKind = selected.first);
                  },
                ),
                const SizedBox(height: 16),
                if (_connectionType != ConnectionType.local) ...[
                  TextField(
                    controller: _targetController,
                    decoration: InputDecoration(
                      labelText: 'Target',
                      hintText: _connectionType == ConnectionType.iroh
                          ? 'user@endpoint_id'
                          : 'user@host or user@host:port',
                      border: const OutlineInputBorder(),
                      suffixIcon: Platform.isAndroid
                          ? IconButton(
                              icon: const Icon(Icons.qr_code_scanner),
                              tooltip: 'Scan QR code',
                              onPressed: () async {
                                final result =
                                    await Navigator.of(context).push<String>(
                                  MaterialPageRoute(
                                    builder: (_) => const QrScannerScreen(),
                                  ),
                                );
                                if (result != null) {
                                  _targetController.text = result;
                                }
                              },
                            )
                          : null,
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => _connect(),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_connectionType == ConnectionType.iroh) ...[
                  ExpansionTile(
                    title: const Text('Advanced'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Override global network settings'),
                        value: _overrideRelays,
                        onChanged: (value) =>
                            setState(() => _overrideRelays = value),
                      ),
                      if (_overrideRelays)
                        NetworkSettingsEditor(
                          value: NetworkSettings(
                            useDefaultRelays: _useDefaultRelays,
                            customRelayUrls: _customRelayUrls,
                            maxRemoteNatTraversalAddresses:
                                _maxRemoteNatTraversalAddresses,
                          ),
                          onChanged: (settings) {
                            setState(() {
                              _useDefaultRelays = settings.useDefaultRelays;
                              _customRelayUrls = settings.customRelayUrls;
                              _maxRemoteNatTraversalAddresses =
                                  settings.maxRemoteNatTraversalAddresses;
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  onPressed: _connecting ? null : _connect,
                  child: _connecting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_tabKind == TabKind.files
                          ? 'Open Files'
                          : _connectionType == ConnectionType.local
                              ? 'Open Shell'
                              : 'Connect'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          if (_savedConnections.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Saved Connections',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _savedConnections.length,
                itemBuilder: (context, index) {
                  final conn = _savedConnections[index];
                  return ListTile(
                    leading: Icon(_iconForConnectionType(conn.connectionType)),
                    title: Text(conn.connectionType == ConnectionType.local
                        ? 'Local'
                        : conn.username),
                    subtitle: Text(
                      _subtitleForConnection(conn),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteConnection(conn),
                    ),
                    onTap: _connecting
                        ? null
                        : () => _onSavedConnectionTap(conn),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}
