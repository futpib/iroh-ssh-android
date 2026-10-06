import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';
import 'package:iroh_ssh_app/services/update_controller.dart';
import 'package:iroh_ssh_app/services/update_release.dart';

void openUpdates(BuildContext context, {UpdateRelease? release}) {
  if (release != null) UpdateController.instance.offer(release);
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Updates')),
        body: const UpdateSettings(),
      ),
    ),
  );
}

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key, this.checker, this.controller});
  final UpdateChecker? checker;
  final UpdateController? controller;

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings>
    with WidgetsBindingObserver {
  late final UpdateController _updates;
  late final bool _ownsController;
  bool? _enabled;
  bool _saving = false;
  String? _settingsError;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null && widget.checker != null;
    _updates =
        widget.controller ??
        (widget.checker == null
            ? UpdateController.instance
            : UpdateController(checker: widget.checker));
    WidgetsBinding.instance.addObserver(this);
    _load();
    _updates.refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_updates.installing) _updates.refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    // Production uses the app-lifetime controller so downloads can outlive this
    // route. Injected controllers are owned by their caller.
    if (_ownsController) _updates.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _updates.refresh();
  }

  Future<void> _load() async {
    try {
      final enabled = await _updates.checker.isEnabled();
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) {
        setState(() => _settingsError = 'Could not load update settings.');
      }
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _saving = true);
    try {
      final settings = await SettingsStorage.instance.load();
      await SettingsStorage.instance.save(
        settings.copyWith(automaticUpdateChecks: value),
      );
      if (mounted) {
        setState(() {
          _enabled = value;
          _settingsError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _settingsError = 'Could not save update settings.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _install() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install update?'),
        content: const Text(
          'Installing restarts Iroh SSH and disconnects active terminals. Finish your work before continuing. Your saved connections and settings will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _updates.install();
  }

  Future<void> _discard() async {
    try {
      await _updates.discard();
    } catch (_) {
      if (mounted) {
        setState(
          () => _settingsError =
              'Could not remove the download. Please try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _updates,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Automatically check for updates'),
          subtitle: const Text(
            'Check GitHub when the app starts. Off by default for detected Obtainium installs.',
          ),
          value: _enabled ?? false,
          onChanged: _enabled == null || _saving ? null : _toggle,
        ),
        const SizedBox(height: 16),
        FilledButton.tonal(
          onPressed: _updates.busy || _updates.installing || _updates.ready
              ? null
              : _updates.check,
          child: Text(_updates.checking ? 'Checking…' : 'Check now'),
        ),
        if (_settingsError != null) Text(_settingsError!),
        if (_updates.message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(_updates.message!),
          ),
        if (_updates.downloading) ...[
          LinearProgressIndicator(
            value: _updates.release == null
                ? null
                : _updates.received / _updates.release!.size,
          ),
          Text(
            '${(_updates.received / 1048576).toStringAsFixed(1)} / ${(_updates.release!.size / 1048576).toStringAsFixed(1)} MB',
          ),
          TextButton(
            onPressed: _updates.cancelDownload,
            child: const Text('Cancel download'),
          ),
        ],
        if (_updates.verifying)
          const ListTile(
            leading: CircularProgressIndicator(),
            title: Text('Verifying APK…'),
          ),
        if (_updates.release != null &&
            !_updates.ready &&
            !_updates.busy &&
            !_updates.installing)
          FilledButton(
            onPressed: _updates.download,
            child: Text(
              'Download update (${(_updates.release!.size / 1048576).toStringAsFixed(1)} MB)',
            ),
          ),
        if (_updates.ready) ...[
          Text('Ready to install: ${_updates.readyVersion}'),
          FilledButton(
            onPressed: _updates.busy || _updates.installing ? null : _install,
            child: Text(_updates.installing ? 'Installing…' : 'Install'),
          ),
          TextButton(
            onPressed: _updates.busy || _updates.installing ? null : _discard,
            child: const Text('Remove download'),
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Downloads stay in Iroh SSH. Installation requires your confirmation in Android.',
        ),
      ],
    ),
  );
}

/// Checks once per app launch without blocking startup or interrupting typing.
class UpdateNotice extends StatefulWidget {
  const UpdateNotice({
    super.key,
    required this.child,
    this.checker,
    this.controller,
  });
  final UpdateChecker? checker;
  final UpdateController? controller;
  final Widget child;

  @override
  State<UpdateNotice> createState() => _UpdateNoticeState();
}

class _UpdateNoticeState extends State<UpdateNotice> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    try {
      final updates = widget.controller ?? UpdateController.instance;
      await updates.refresh();
      if (!mounted) return;
      if (updates.message?.startsWith('Updated to ') == true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(updates.message!)));
      }
      final checker = widget.checker ?? UpdateChecker.instance;
      if (!await checker.isEnabled() || updates.ready || updates.installing) {
        return;
      }
      final release = await checker.check();
      if (release == null || !mounted || !await checker.isEnabled()) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Iroh SSH update available: ${release.tag}'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Update',
            onPressed: () => openUpdates(context, release: release),
          ),
        ),
      );
    } catch (_) {
      // Offline/rate-limited automatic checks must not disrupt a session.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
