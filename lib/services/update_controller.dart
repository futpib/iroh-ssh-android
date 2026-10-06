import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:iroh_ssh_app/services/settings_storage.dart';
import 'package:iroh_ssh_app/services/update_checker.dart';
import 'package:iroh_ssh_app/services/update_downloader.dart';
import 'package:iroh_ssh_app/services/update_release.dart';

/// Shared by the settings tab and the startup notice's update screen. Leaving a
/// screen does not lose a download or register a second install attempt.
class UpdateController extends ChangeNotifier {
  UpdateController({UpdateChecker? checker, UpdateDownloader? downloader})
    : checker = checker ?? UpdateChecker.instance,
      downloader = downloader ?? UpdateDownloader();
  static final instance = UpdateController();
  final UpdateChecker checker;
  final UpdateDownloader downloader;
  UpdateRelease? release;
  bool busy = false;
  bool checking = false;
  bool downloading = false;
  bool verifying = false;
  bool installing = false;
  bool ready = false;
  bool canInstall = false;
  int received = 0;
  String? readyVersion;
  String? message;

  Future<void> refresh() async {
    if (busy) return;
    busy = true;
    try {
      final state =
          await UpdateChecker.channel.invokeMapMethod<String, dynamic>(
            'updateState',
          ) ??
          {};
      ready = state['ready'] == true;
      canInstall = state['canInstall'] == true;
      installing = state['status'] == 'installing';
      readyVersion = state['version'] as String?;
      message = state['message'] as String? ?? message;
      if (state['status'] == 'installed') {
        release = null;
        await UpdateChecker.channel.invokeMethod<void>('acknowledgeUpdate');
      }
    } catch (_) {
      message = 'Could not read update status. Please try again.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> check() async {
    if (busy || installing || ready) return;
    busy = checking = true;
    release = null;
    message = null;
    notifyListeners();
    try {
      release = await checker.check();
      message = release == null
          ? 'You’re up to date.'
          : 'Update available: ${release!.tag}';
    } catch (_) {
      message = 'Could not check for updates. Please try again later.';
    } finally {
      busy = checking = false;
      notifyListeners();
    }
  }

  void offer(UpdateRelease update) {
    if (busy || ready || installing) return;
    release = update;
    message = 'Update available: ${update.tag}';
    notifyListeners();
  }

  Future<void> download() async {
    final update = release;
    if (update == null || busy || installing || ready) return;
    busy = downloading = true;
    received = 0;
    message = null;
    notifyListeners();
    try {
      await UpdateChecker.channel.invokeMethod<void>('discardUpdate');
      final path = await UpdateChecker.channel.invokeMethod<String>(
        'downloadPath',
      );
      if (path == null) throw StateError('Missing download path');
      await downloader.download(update, File(path), (bytes) {
        received = bytes;
        notifyListeners();
      });
      downloading = false;
      verifying = true;
      notifyListeners();
      await UpdateChecker.channel.invokeMethod<void>(
        'prepareUpdate',
        update.verification,
      );
      message = 'Update downloaded and verified.';
    } on UpdateDownloadCancelled {
      message = 'Download cancelled. You can retry.';
    } catch (e) {
      message = e is PlatformException
          ? e.message
          : 'Download failed. Please try again.';
    } finally {
      busy = downloading = verifying = false;
      await refresh();
      notifyListeners();
    }
  }

  void cancelDownload() => downloader.cancel();

  Future<void> discard() async {
    if (busy || installing) return;
    await UpdateChecker.channel.invokeMethod<void>('discardUpdate');
    ready = false;
    readyVersion = null;
    message = 'Downloaded update removed.';
    notifyListeners();
  }

  Future<void> install() async {
    if (busy || installing || !ready) return;
    busy = true;
    message = 'Preparing installation…';
    notifyListeners();
    try {
      // Self-updates can change Android's installer record. Preserve the current
      // setting, including an Obtainium-derived default, across this replacement.
      final settings = await SettingsStorage.instance.load();
      if (settings.automaticUpdateChecks == null) {
        final enabled = await checker.isEnabled();
        final latest = await SettingsStorage.instance.load();
        if (latest.automaticUpdateChecks == null) {
          await SettingsStorage.instance.save(
            latest.copyWith(automaticUpdateChecks: enabled),
          );
        }
      }
      final result = await UpdateChecker.channel
          .invokeMapMethod<String, dynamic>('installUpdate');
      if (result?['permissionRequired'] == true) {
        message = 'Allow installation from Iroh SSH, then tap Install again.';
        await UpdateChecker.channel.invokeMethod<void>('openInstallSettings');
      } else {
        message =
            'Confirm installation in Android. Reopen Iroh SSH when it finishes.';
      }
    } catch (e) {
      message = e is PlatformException
          ? e.message
          : 'Could not start installation. Please try again.';
    } finally {
      busy = false;
      await refresh();
      notifyListeners();
    }
  }
}
