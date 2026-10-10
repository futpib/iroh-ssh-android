package com.github.futpib.iroh_ssh_app

import android.app.Activity
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.openintents.ssh.authentication.ISshAuthenticationService
import org.openintents.ssh.authentication.SshAuthenticationApi
import org.openintents.ssh.authentication.SshAuthenticationApiError
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Bridges Flutter to any installed implementation of the OpenKeychain SSH
 * authentication API. Private key material never enters this application. */
object OpenKeychainBridge {
    private const val CHANNEL = "iroh_ssh/openkeychain"
    private const val FIRST_REQUEST_CODE = 47000

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newCachedThreadPool()
    private val interactions = mutableMapOf<Int, Operation>()

    private lateinit var appContext: Context
    private var activity = WeakReference<MainActivity>(null)
    private var nextRequestCode = FIRST_REQUEST_CODE

    private enum class ResultKind { KEY, PUBLIC_KEY, SIGNATURE }

    private class Operation(
        val providerPackage: String,
        val kind: ResultKind,
        val result: MethodChannel.Result,
    ) {
        val completed = AtomicBoolean(false)
    }

    fun register(messenger: BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler(::handleCall)
    }

    fun attachActivity(value: MainActivity) {
        activity = WeakReference(value)
    }

    fun detachActivity(value: MainActivity) {
        if (activity.get() === value) activity.clear()
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listProviders" -> result.success(listProviders())
            "selectKey" -> {
                val operation = operation(call, ResultKind.KEY, result) ?: return
                execute(operation, Intent(SshAuthenticationApi.ACTION_SELECT_KEY))
            }
            "getSshPublicKey" -> {
                val operation = operation(call, ResultKind.PUBLIC_KEY, result) ?: return
                val keyId = requiredString(call, "keyId", result) ?: return
                execute(
                    operation,
                    Intent(SshAuthenticationApi.ACTION_GET_SSH_PUBLIC_KEY).apply {
                        putExtra(SshAuthenticationApi.EXTRA_KEY_ID, keyId)
                    },
                )
            }
            "sign" -> {
                val operation = operation(call, ResultKind.SIGNATURE, result) ?: return
                val keyId = requiredString(call, "keyId", result) ?: return
                val challenge = call.argument<ByteArray>("challenge")
                val hashAlgorithm = call.argument<Int>("hashAlgorithm")
                if (challenge == null || hashAlgorithm == null) {
                    result.error(
                        "invalid_arguments",
                        "challenge and hashAlgorithm are required",
                        null,
                    )
                    return
                }
                execute(
                    operation,
                    Intent(SshAuthenticationApi.ACTION_SIGN).apply {
                        putExtra(SshAuthenticationApi.EXTRA_KEY_ID, keyId)
                        putExtra(SshAuthenticationApi.EXTRA_CHALLENGE, challenge)
                        putExtra(SshAuthenticationApi.EXTRA_HASH_ALGORITHM, hashAlgorithm)
                    },
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun operation(
        call: MethodCall,
        kind: ResultKind,
        result: MethodChannel.Result,
    ): Operation? {
        val provider = requiredString(call, "providerPackage", result) ?: return null
        return Operation(provider, kind, result)
    }

    private fun requiredString(
        call: MethodCall,
        name: String,
        result: MethodChannel.Result,
    ): String? {
        val value = call.argument<String>(name)
        if (value.isNullOrBlank()) {
            result.error("invalid_arguments", "$name is required", null)
            return null
        }
        return value
    }

    private fun listProviders(): List<Map<String, String>> {
        val intent = Intent(SshAuthenticationApi.SERVICE_INTENT)
        val services = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.packageManager.queryIntentServices(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            appContext.packageManager.queryIntentServices(intent, PackageManager.MATCH_ALL)
        }
        return services
            .distinctBy { it.serviceInfo.packageName }
            .map {
                mapOf(
                    "packageName" to it.serviceInfo.packageName,
                    "label" to it.loadLabel(appContext.packageManager).toString(),
                )
            }
    }

    private fun execute(operation: Operation, request: Intent) {
        mainHandler.post {
            if (operation.completed.get()) return@post

            val serviceIntent = Intent(SshAuthenticationApi.SERVICE_INTENT).apply {
                setPackage(operation.providerPackage)
            }
            var bound = false
            val connectionFinished = AtomicBoolean(false)
            lateinit var connection: ServiceConnection
            connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                    worker.execute {
                        val response = try {
                            val service = ISshAuthenticationService.Stub.asInterface(binder)
                            SshAuthenticationApi(appContext, service).executeApi(request)
                        } catch (error: Exception) {
                            mainHandler.post {
                                finishError(
                                    operation,
                                    "openkeychain_error",
                                    "OpenKeychain request failed: ${error.message}",
                                )
                            }
                            null
                        }
                        mainHandler.post {
                            if (connectionFinished.compareAndSet(false, true) && bound) {
                                try {
                                    appContext.unbindService(connection)
                                } catch (_: IllegalArgumentException) {
                                }
                            }
                            if (response != null) processResponse(operation, response)
                        }
                    }
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    if (connectionFinished.compareAndSet(false, true)) {
                        finishError(
                            operation,
                            "openkeychain_disconnected",
                            "The OpenKeychain provider disconnected",
                        )
                    }
                }

                override fun onNullBinding(name: ComponentName) {
                    if (connectionFinished.compareAndSet(false, true)) {
                        if (bound) appContext.unbindService(this)
                        finishError(
                            operation,
                            "openkeychain_unavailable",
                            "The selected OpenKeychain provider is unavailable",
                        )
                    }
                }
            }

            bound = try {
                appContext.bindService(serviceIntent, connection, Context.BIND_AUTO_CREATE)
            } catch (_: SecurityException) {
                false
            }
            if (!bound && connectionFinished.compareAndSet(false, true)) {
                finishError(
                    operation,
                    "openkeychain_unavailable",
                    "The selected OpenKeychain provider is not installed or cannot be opened",
                )
            }
        }
    }

    private fun processResponse(operation: Operation, response: Intent) {
        response.extras?.classLoader = SshAuthenticationApiError::class.java.classLoader
        val resultCode = response.getIntExtra(
            SshAuthenticationApi.EXTRA_RESULT_CODE,
            SshAuthenticationApi.RESULT_CODE_ERROR,
        )
        when (resultCode) {
            SshAuthenticationApi.RESULT_CODE_SUCCESS -> when (operation.kind) {
                ResultKind.KEY -> {
                    val keyId = response.getStringExtra(SshAuthenticationApi.EXTRA_KEY_ID)
                    if (keyId == null) {
                        finishError(operation, "openkeychain_invalid_result", "Provider returned no key ID")
                    } else {
                        finishSuccess(
                            operation,
                            mapOf(
                                "keyId" to keyId,
                                "description" to
                                    (response.getStringExtra(SshAuthenticationApi.EXTRA_KEY_DESCRIPTION) ?: keyId),
                            ),
                        )
                    }
                }
                ResultKind.PUBLIC_KEY -> {
                    val key = response.getStringExtra(SshAuthenticationApi.EXTRA_SSH_PUBLIC_KEY)
                    if (key == null) {
                        finishError(
                            operation,
                            "openkeychain_invalid_result",
                            "Provider returned no SSH public key",
                        )
                    } else {
                        finishSuccess(operation, key)
                    }
                }
                ResultKind.SIGNATURE -> {
                    val signature = response.getByteArrayExtra(SshAuthenticationApi.EXTRA_SIGNATURE)
                    if (signature == null) {
                        finishError(
                            operation,
                            "openkeychain_invalid_result",
                            "Provider returned no SSH signature",
                        )
                    } else {
                        finishSuccess(operation, signature)
                    }
                }
            }
            SshAuthenticationApi.RESULT_CODE_USER_INTERACTION_REQUIRED -> {
                val pendingIntent = pendingIntent(response)
                val currentActivity = activity.get()
                if (pendingIntent == null) {
                    finishError(
                        operation,
                        "openkeychain_invalid_result",
                        "Provider requested interaction without an intent",
                    )
                } else if (currentActivity == null) {
                    finishError(
                        operation,
                        "openkeychain_interaction_required",
                        "Open Iroh SSH to approve the OpenKeychain request",
                    )
                } else {
                    if (nextRequestCode > 65000) nextRequestCode = FIRST_REQUEST_CODE
                    val requestCode = nextRequestCode++
                    interactions[requestCode] = operation
                    try {
                        currentActivity.startIntentSenderForResult(
                            pendingIntent.intentSender,
                            requestCode,
                            null,
                            0,
                            0,
                            0,
                        )
                    } catch (error: Exception) {
                        interactions.remove(requestCode)
                        finishError(
                            operation,
                            "openkeychain_interaction_failed",
                            "Could not open OpenKeychain: ${error.message}",
                        )
                    }
                }
            }
            else -> {
                val error = authenticationError(response)
                finishError(
                    operation,
                    "openkeychain_error",
                    error?.message ?: "The OpenKeychain provider rejected the request",
                    error?.error,
                )
            }
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val operation = interactions.remove(requestCode) ?: return false
        if (resultCode != Activity.RESULT_OK || data == null) {
            finishError(operation, "openkeychain_cancelled", "OpenKeychain request was cancelled")
        } else {
            execute(operation, data)
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun pendingIntent(intent: Intent): PendingIntent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(SshAuthenticationApi.EXTRA_PENDING_INTENT, PendingIntent::class.java)
        } else {
            intent.getParcelableExtra(SshAuthenticationApi.EXTRA_PENDING_INTENT)
        }

    @Suppress("DEPRECATION")
    private fun authenticationError(intent: Intent): SshAuthenticationApiError? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(SshAuthenticationApi.EXTRA_ERROR, SshAuthenticationApiError::class.java)
        } else {
            intent.getParcelableExtra(SshAuthenticationApi.EXTRA_ERROR)
        }

    private fun finishSuccess(operation: Operation, value: Any) {
        if (operation.completed.compareAndSet(false, true)) operation.result.success(value)
    }

    private fun finishError(
        operation: Operation,
        code: String,
        message: String,
        details: Any? = null,
    ) {
        if (operation.completed.compareAndSet(false, true)) {
            operation.result.error(code, message, details)
        }
    }
}
