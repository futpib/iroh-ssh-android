import 'package:flutter/material.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';

Future<void> openUpdateRelease(BuildContext context) async {
  try {
    await UpdateChecker.instance.openRelease();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open browser. Visit github.com/futpib/iroh-ssh-android/releases',
          ),
        ),
      );
    }
  }
}

class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key, this.checker});
  final UpdateChecker? checker;

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  bool? _enabled;
  bool _checking = false;
  bool _saving = false;
  String? _status;
  String? _release;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await (widget.checker ?? UpdateChecker.instance)
          .isEnabled();
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) setState(() => _status = 'Could not load update settings.');
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _saving = true);
    try {
      final settings = await SettingsStorage.instance.load();
      await SettingsStorage.instance.save(
        settings.copyWith(automaticUpdateChecks: value),
      );
      if (mounted) setState(() => _enabled = value);
    } catch (_) {
      if (mounted) setState(() => _status = 'Could not save update settings.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _status = null;
      _release = null;
    });
    try {
      final release = await (widget.checker ?? UpdateChecker.instance).check();
      if (mounted) {
        setState(() {
          _release = release;
          _status = release == null
              ? 'You’re up to date.'
              : 'Update available: $release';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _status = 'Could not check for updates. Please try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
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
        onPressed: _checking ? null : _check,
        child: Text(_checking ? 'Checking…' : 'Check now'),
      ),
      if (_status != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(_status!),
        ),
      if (_release != null)
        TextButton(
          onPressed: () => openUpdateRelease(context),
          child: const Text('View release'),
        ),
      const Text(
        'Updates open in your browser. Keep the same APK architecture and scanner variant when downloading.',
      ),
    ],
  );
}

/// Checks once per app launch without blocking startup or interrupting typing.
class UpdateNotice extends StatefulWidget {
  const UpdateNotice({super.key, required this.child, this.checker});
  final UpdateChecker? checker;
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
      if (!await (widget.checker ?? UpdateChecker.instance).isEnabled()) return;
      final release = await (widget.checker ?? UpdateChecker.instance).check();
      // A user may have switched checks off while the request was in flight.
      if (release == null ||
          !mounted ||
          !await (widget.checker ?? UpdateChecker.instance).isEnabled()) {
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Iroh SSH update available: $release'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'View release',
            onPressed: () => openUpdateRelease(context),
          ),
        ),
      );
    } catch (_) {
      // Offline/rate-limited startup checks must not disrupt a session.
      // The manual check in Settings gives visible error feedback.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
