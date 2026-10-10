package com.github.futpib.iroh_ssh_app

import android.content.Intent
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

        AppUpdates.register(flutterEngine.dartExecutor.binaryMessenger, this)

        // Available on the UI engine for any direct (in-process) callers.
        MediaStoreSaver.register(flutterEngine.dartExecutor.binaryMessenger, this)
        OpenKeychainBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)

        // And on the foreground-service engine, where transfers actually run.
        if (!lifecycleListenerRegistered) {
            lifecycleListenerRegistered = true
            FlutterForegroundTaskPlugin.addTaskLifecycleListener(FgtEngineListener(applicationContext))
        }
    }

    override fun onResume() {
        super.onResume()
        OpenKeychainBridge.attachActivity(this)
    }

    override fun onPause() {
        OpenKeychainBridge.detachActivity(this)
        super.onPause()
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        OpenKeychainBridge.attachActivity(this)
        if (!OpenKeychainBridge.handleActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
