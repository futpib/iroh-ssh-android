package com.github.futpib.iroh_ssh_app

import android.content.Context
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

/**
 * Registers our platform channels on the foreground-service's FlutterEngine the
 * moment it's created, so the background isolate (which runs the SFTP transfers)
 * can drive the progress notifications and publish downloads via MediaStore —
 * without any of it touching the UI isolate. flutter_foreground_task does not
 * run GeneratedPluginRegistrant on the service engine, so this hook is how the
 * channels become reachable there.
 */
class FgtEngineListener(context: Context) : FlutterForegroundTaskLifecycleListener {
    private val appContext = context.applicationContext

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MediaStoreSaver.register(messenger, appContext)
        TransferNotificationManager.register(messenger, appContext)
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}

    override fun onTaskRepeatEvent() {}

    override fun onTaskDestroy() {}

    override fun onEngineWillDestroy() {
        TransferNotificationManager.unregister()
    }
}
