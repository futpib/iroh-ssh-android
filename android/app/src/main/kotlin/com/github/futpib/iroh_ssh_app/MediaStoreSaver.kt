package com.github.futpib.iroh_ssh_app

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Publishes files into the device's public Downloads via MediaStore. Exposed on
 * the `iroh_ssh/mediastore` channel and registered on BOTH the UI engine and the
 * foreground-service engine, so a download finishing in the background isolate
 * can publish without involving the UI isolate.
 */
object MediaStoreSaver {
    private const val CHANNEL = "iroh_ssh/mediastore"

    // The copy can be hundreds of MB; never run it on the platform/main thread.
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Retain the channels (one per engine) so they aren't garbage-collected —
    // an unreferenced MethodChannel silently stops handling calls.
    private val channels = mutableListOf<MethodChannel>()

    fun register(messenger: BinaryMessenger, context: Context) {
        val appContext = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channels.add(channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val displayName = call.argument<String>("displayName")
                    val mimeType =
                        call.argument<String>("mimeType") ?: "application/octet-stream"
                    if (sourcePath == null || displayName == null) {
                        result.error("ARGS", "sourcePath and displayName are required", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        try {
                            val saved =
                                saveToDownloads(appContext, File(sourcePath), displayName, mimeType)
                            main.post { result.success(saved) }
                        } catch (e: Exception) {
                            main.post { result.error("SAVE_FAILED", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Copies [src] into the device's public Downloads collection via MediaStore
     * (Android 10+), streaming so large files don't load into memory. The MIME
     * type is resolved from the file extension (falling back to [mimeType]) so
     * the file opens with the right app. Returns a map of `uri` (the content://
     * URI, for "open") and `displayPath` ("Downloads/<name>"), or null on
     * Android < 10 (the caller then falls back to the app's external files dir).
     */
    private fun saveToDownloads(
        context: Context,
        src: File,
        displayName: String,
        mimeType: String,
    ): HashMap<String, String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null

        val resolver = context.contentResolver
        val ext = displayName.substringAfterLast('.', "")
        val resolvedMime = (if (ext.isNotEmpty()) {
            android.webkit.MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(ext.lowercase())
        } else {
            null
        }) ?: mimeType
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, resolvedMime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore insert returned null")
        try {
            resolver.openOutputStream(uri).use { out ->
                if (out == null) throw IllegalStateException("Could not open output stream")
                src.inputStream().use { input -> input.copyTo(out) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return hashMapOf(
                "uri" to uri.toString(),
                "displayPath" to "Downloads/$displayName",
            )
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
