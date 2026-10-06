package com.github.futpib.iroh_ssh_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodChannel

import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    companion object {
        // Guard against registering the service-engine listener more than once
        // (configureFlutterEngine runs again if the activity is recreated).
        private var lifecycleListenerRegistered = false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iroh_ssh/updates")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "appInfo" -> {
                            @Suppress("DEPRECATION")
                            val info = packageManager.getPackageInfo(packageName, 0)
                            val installer = try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                    packageManager.getInstallSourceInfo(packageName).installingPackageName
                                } else {
                                    @Suppress("DEPRECATION")
                                    packageManager.getInstallerPackageName(packageName)
                                }
                            } catch (_: Exception) { null }
                            result.success(mapOf("version" to info.versionName, "installer" to installer))
                        }
                        "openRelease" -> {
                            // Fixed destination: never launch a URL supplied by a release response.
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(
                                "https://github.com/futpib/iroh-ssh-android/releases/latest"
                            )))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("UPDATE_ERROR", e.message, null)
                }
            }

        // Available on the UI engine for any direct (in-process) callers.
        MediaStoreSaver.register(flutterEngine.dartExecutor.binaryMessenger, this)

        // And on the foreground-service engine, where transfers actually run.
        if (!lifecycleListenerRegistered) {
            lifecycleListenerRegistered = true
            FlutterForegroundTaskPlugin.addTaskLifecycleListener(FgtEngineListener(applicationContext))
        }
    }
}
