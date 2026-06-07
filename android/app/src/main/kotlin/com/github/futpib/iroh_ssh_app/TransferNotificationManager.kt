package com.github.futpib.iroh_ssh_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the per-transfer progress notifications (a real, native progress bar with
 * a Cancel action). Driven over the `iroh_ssh/transfer` channel from the
 * foreground-service isolate (where the SFTP bytes move), so nothing runs on the
 * UI thread. A Cancel tap is routed back to that same isolate via [handleCancel].
 */
object TransferNotificationManager {
    private const val CHANNEL = "iroh_ssh/transfer"
    private const val NOTIF_CHANNEL_ID = "iroh_ssh_transfers"
    const val ACTION_CANCEL = "com.github.futpib.iroh_ssh_app.TRANSFER_CANCEL"
    const val EXTRA_REQUEST_ID = "requestId"

    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    // Stable int notification id per (string) transfer requestId.
    private val ids = HashMap<String, Int>()
    private var nextId = 9000

    fun register(messenger: BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        ensureChannel()
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        show(
                            requestId = call.argument<String>("requestId")!!,
                            title = call.argument<String>("title") ?: "",
                            text = call.argument<String>("text") ?: "",
                            max = call.argument<Int>("max") ?: 0,
                            progress = call.argument<Int>("progress") ?: 0,
                            indeterminate = call.argument<Boolean>("indeterminate") ?: false,
                            ongoing = call.argument<Boolean>("ongoing") ?: true,
                            showCancel = call.argument<Boolean>("showCancel") ?: true,
                            isUpload = call.argument<Boolean>("isUpload") ?: false,
                            openUri = call.argument<String>("openUri"),
                        )
                        result.success(null)
                    }
                    "cancel" -> {
                        cancel(call.argument<String>("requestId")!!)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** Called by [TransferCancelReceiver] when the user taps Cancel. */
    fun handleCancel(requestId: String) {
        channel?.invokeMethod("onCancel", requestId)
    }

    private fun notifId(requestId: String): Int = ids.getOrPut(requestId) { nextId++ }

    private fun notificationManager(): NotificationManager? =
        appContext?.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = notificationManager() ?: return
        if (nm.getNotificationChannel(NOTIF_CHANNEL_ID) == null) {
            val ch = NotificationChannel(
                NOTIF_CHANNEL_ID,
                "File transfers",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Upload and download progress" }
            nm.createNotificationChannel(ch)
        }
    }

    private fun show(
        requestId: String,
        title: String,
        text: String,
        max: Int,
        progress: Int,
        indeterminate: Boolean,
        ongoing: Boolean,
        showCancel: Boolean,
        isUpload: Boolean,
        openUri: String?,
    ) {
        val ctx = appContext ?: return
        val id = notifId(requestId)
        val smallIcon =
            if (isUpload) android.R.drawable.stat_sys_upload
            else android.R.drawable.stat_sys_download

        val builder = NotificationCompat.Builder(ctx, NOTIF_CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (max > 0 || indeterminate) {
            builder.setProgress(max, progress, indeterminate)
        }

        // Tapping a finished download opens it (ACTION_VIEW on the content URI).
        if (openUri != null) {
            val uri = android.net.Uri.parse(openUri)
            val type = ctx.contentResolver.getType(uri) ?: "*/*"
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, type)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK,
                )
            }
            var viewFlags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                viewFlags = viewFlags or PendingIntent.FLAG_IMMUTABLE
            }
            builder.setContentIntent(PendingIntent.getActivity(ctx, id, viewIntent, viewFlags))
            builder.setAutoCancel(true)
        }

        if (showCancel) {
            val intent = Intent(ctx, TransferCancelReceiver::class.java).apply {
                action = ACTION_CANCEL
                putExtra(EXTRA_REQUEST_ID, requestId)
            }
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            val pi = PendingIntent.getBroadcast(ctx, id, intent, flags)
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", pi)
        }

        notificationManager()?.notify(id, builder.build())
    }

    private fun cancel(requestId: String) {
        val id = ids.remove(requestId) ?: return
        notificationManager()?.cancel(id)
    }
}

/** Receives the notification's Cancel action and forwards it to the isolate. */
class TransferCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TransferNotificationManager.ACTION_CANCEL) return
        val requestId =
            intent.getStringExtra(TransferNotificationManager.EXTRA_REQUEST_ID) ?: return
        TransferNotificationManager.handleCancel(requestId)
    }
}
