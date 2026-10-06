package com.github.futpib.iroh_ssh_app

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

/** APK parsing, hashing and session writes run off the UI thread. State survives
 * activity/process replacement; the installed version is the success authority. */
object AppUpdates {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private const val SCANNER = "iroh.update.scanner"
    private const val PACKAGING = "iroh.update.packaging"
    private const val BASE_CODE = "iroh.update.baseCode"
    private val abis = setOf("armeabi-v7a", "arm64-v8a", "x86_64")

    fun prefs(context: Context) = context.getSharedPreferences("app_updates", Context.MODE_PRIVATE)
    private fun apk(context: Context) = File(context.cacheDir, "app-update/update.apk")
    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun flags(): Int = PackageManager.GET_META_DATA or
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    private fun installed(context: Context) = context.packageManager.getPackageInfo(context.packageName, flags())
    private fun metadata(info: PackageInfo, key: String): String? =
        info.applicationInfo?.metaData?.get(key)?.toString()

    private fun apkAbis(path: String): Set<String> = ZipFile(path).use { zip ->
        zip.entries().asSequence().map { it.name }
            .filter { it.startsWith("lib/") && it.endsWith("/libflutter.so") }
            .map { it.split('/')[1] }.toSet()
    }

    private fun assetName(info: PackageInfo, path: String): String {
        val scanner = metadata(info, SCANNER)
        require(scanner == "fdroid" || scanner == "mlkit") { "This build has no supported update variant." }
        val architecture = when (metadata(info, PACKAGING)) {
            "universal" -> ""
            "split" -> {
                val libraries = apkAbis(path)
                require(libraries.size == 1 && libraries.first() in abis) { "Unsupported APK architecture." }
                "-${libraries.first()}"
            }
            else -> error("This build has no update packaging metadata.")
        }
        return "app${architecture}-release${if (scanner == "fdroid") "-fdroid" else ""}.apk"
    }

    @Suppress("DEPRECATION")
    private fun signatures(info: PackageInfo): Set<String> {
        val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signers?.map { it.toCharsString() }?.toSet() ?: emptySet()
    }

    @Suppress("DEPRECATION")
    private fun validate(context: Context, version: String, baseCode: Long, name: String,
                         digest: String, size: Long): PackageInfo {
        val file = apk(context)
        require(file.isFile && file.length() == size && size > 0) { "The downloaded APK is incomplete. Download it again." }
        require(digest.matches(Regex("[a-f0-9]{64}"))) { "Missing APK checksum." }
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        require(hash.digest().joinToString("") { "%02x".format(it) } == digest) { "APK checksum mismatch. Download it again." }
        val candidate = context.packageManager.getPackageArchiveInfo(file.path, flags())
            ?: error("The downloaded file is not a valid APK.")
        val current = installed(context)
        require(candidate.packageName == context.packageName) { "The APK belongs to a different app." }
        require(candidate.versionName == version && metadata(candidate, BASE_CODE)?.toLongOrNull() == baseCode) {
            "APK version does not match the release."
        }
        require(code(candidate) > code(current)) { "This APK is not newer than the installed app." }
        val trusted = signatures(current)
        require(trusted.isNotEmpty() && signatures(candidate) == trusted) { "APK signing certificate does not match this app." }
        require(assetName(current, context.applicationInfo.sourceDir) == name && assetName(candidate, file.path) == name) {
            "The APK architecture or scanner variant does not match this app."
        }
        // Also require the actual native ABI set to match, including universal builds.
        require(apkAbis(context.applicationInfo.sourceDir) == apkAbis(file.path)) { "APK native architectures do not match." }
        return candidate
    }

    private fun canInstall(context: Context) = Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()

    private fun state(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val current = installed(context)
        val expected = p.getLong("expectedCode", 0)
        if (expected > 0 && code(current) >= expected) {
            apk(context).delete()
            p.edit().clear().putString("status", "installed")
                .putString("message", "Updated to ${current.versionName}.").commit()
        } else if (p.getString("status", null) == "installing" &&
            context.packageManager.packageInstaller.getSessionInfo(p.getInt("sessionId", -1)) == null) {
            p.edit().putString("status", "failed").putString("message", "Installation did not complete. You can retry.").commit()
        }
        val ready = p.contains("digest") && apk(context).isFile
        return mapOf("ready" to ready, "status" to p.getString("status", "idle"),
            "message" to p.getString("message", null), "version" to p.getString("version", null),
            "canInstall" to canInstall(context))
    }

    private fun requireIdle(context: Context) {
        require(state(context)["status"] != "installing") { "An installation is already in progress." }
    }

    private fun install(context: Context): Map<String, Any?> {
        requireIdle(context)
        if (!canInstall(context)) return mapOf("permissionRequired" to true)
        val p = prefs(context)
        val candidate = validate(context, p.getString("version", "")!!, p.getLong("baseCode", 0),
            p.getString("assetName", "")!!, p.getString("digest", "")!!, p.getLong("size", 0))
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk(context).length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, apk(context).length()).use { output ->
                    apk(context).inputStream().use { it.copyTo(output, 65536) }
                    session.fsync(output)
                }
                // Persist before commit; success may kill this process before a callback.
                check(p.edit().putInt("sessionId", sessionId).putLong("expectedCode", code(candidate))
                    .putString("status", "installing").remove("message").commit()) { "Could not save installation state." }
                val intent = Intent(context, UpdateInstallReceiver::class.java).apply {
                    action = "${context.packageName}.UPDATE_RESULT"
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val callback = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                session.commit(callback.intentSender)
            }
        } catch (e: Exception) {
            installer.abandonSession(sessionId)
            p.edit().putString("status", "failed").putString("message", "Installation could not start. You can retry.").commit()
            throw e
        }
        return mapOf("permissionRequired" to false)
    }

    fun register(messenger: BinaryMessenger, activity: Activity) {
        val context = activity.applicationContext
        MethodChannel(messenger, "iroh_ssh/updates").setMethodCallHandler { call, result ->
            if (call.method == "openInstallSettings") {
                try {
                    if (Build.VERSION.SDK_INT >= 26) activity.startActivity(Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
                    result.success(null)
                } catch (e: Exception) { result.error("UPDATE_ERROR", e.message, null) }
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    val value: Any? = when (call.method) {
                        "appInfo" -> {
                            val info = installed(context)
                            val source = try {
                                if (Build.VERSION.SDK_INT >= 30) context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
                                else {
                                    @Suppress("DEPRECATION")
                                    context.packageManager.getInstallerPackageName(context.packageName)
                                }
                            } catch (_: Exception) { null }
                            mapOf("version" to info.versionName, "versionCode" to code(info),
                                "baseCode" to metadata(info, BASE_CODE)?.toLongOrNull(), "installer" to source,
                                "assetName" to assetName(info, context.applicationInfo.sourceDir))
                        }
                        "downloadPath" -> apk(context).path
                        "updateState" -> state(context)
                        "acknowledgeUpdate" -> {
                            if (prefs(context).getString("status", null) == "installed") prefs(context).edit().clear().commit()
                            null
                        }
                        "discardUpdate" -> {
                            requireIdle(context)
                            require(!apk(context).exists() || apk(context).delete()) { "Could not remove the previous download." }
                            prefs(context).edit().clear().commit()
                            null
                        }
                        "prepareUpdate" -> {
                            requireIdle(context)
                            val version = call.argument<String>("version")!!
                            val baseCode = call.argument<Number>("baseCode")!!.toLong()
                            val name = call.argument<String>("assetName")!!
                            val digest = call.argument<String>("digest")!!
                            val size = call.argument<Number>("size")!!.toLong()
                            validate(context, version, baseCode, name, digest, size)
                            check(prefs(context).edit().clear().putString("version", version).putLong("baseCode", baseCode)
                                .putString("assetName", name).putString("digest", digest).putLong("size", size)
                                .putString("status", "ready").commit()) { "Could not save update state." }
                            null
                        }
                        "installUpdate" -> install(context)
                        else -> throw UnsupportedOperationException("Unknown update method")
                    }
                    main.post { result.success(value) }
                } catch (e: Exception) {
                    main.post { result.error("UPDATE_ERROR", e.message ?: "Update failed", null) }
                }
            }
        }
    }
}

class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val p = AppUpdates.prefs(context)
        if (intent.action != "${context.packageName}.UPDATE_RESULT" ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -2) != p.getInt("sessionId", -1)) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            try {
                @Suppress("DEPRECATION")
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    ?: error("Missing installation confirmation")
                context.startActivity(confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: Exception) {
                context.packageManager.packageInstaller.abandonSession(p.getInt("sessionId", -1))
                p.edit().putString("status", "failed").putString("message", "Return to the app and try installing again.").commit()
            }
        } else if (status != PackageInstaller.STATUS_SUCCESS) {
            val cancelled = status == PackageInstaller.STATUS_FAILURE_ABORTED
            p.edit().putString("status", if (cancelled) "cancelled" else "failed")
                .putString("message", if (cancelled) "Installation cancelled. You can retry." else "Android could not install the update. You can retry.").commit()
        }
        // Success is confirmed from the installed package version at next launch.
    }
}
