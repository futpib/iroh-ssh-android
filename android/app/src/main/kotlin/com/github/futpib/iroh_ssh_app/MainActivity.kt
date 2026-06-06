package com.github.futpib.iroh_ssh_app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val mediaStoreChannel = "iroh_ssh/mediastore"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaStoreChannel)
            .setMethodCallHandler { call, result ->
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
                        try {
                            result.success(saveToDownloads(File(sourcePath), displayName, mimeType))
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Copies [src] into the device's public Downloads collection via MediaStore
     * (Android 10+), streaming so large files don't load into memory. Returns a
     * human-readable "Downloads/<name>" path, or null on Android < 10 (the
     * caller then falls back to the app's external files dir).
     */
    private fun saveToDownloads(src: File, displayName: String, mimeType: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null

        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
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
            return "Downloads/$displayName"
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
