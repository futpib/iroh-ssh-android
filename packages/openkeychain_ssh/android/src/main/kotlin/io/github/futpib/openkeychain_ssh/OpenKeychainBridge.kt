package io.github.futpib.openkeychain_ssh

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
import java.util.concurrent.Future
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** Bridges Flutter to any installed implementation of the OpenKeychain SSH
 * authentication API. Private key material never enters this application. */
object OpenKeychainBridge {
    private const val CHANNEL = "io.github.futpib.openkeychain_ssh"
    private const val FIRST_REQUEST_CODE = 47000

    private val mainHandler = Handler(Looper.getMainLooper())
    // A provider's binder call cannot always be interrupted. Bound the number
    // of stranded workers instead of growing a new thread on every retry.
    private val worker = ThreadPoolExecutor(0, 2, 60, TimeUnit.SECONDS, SynchronousQueue())
    private val operations = mutableSetOf<Operation>()
    private val interactions = mutableMapOf<Int, Operation>()
    private val channels = mutableMapOf<BinaryMessenger, MethodChannel>()

    private lateinit var appContext: Context
    private var activity = WeakReference<Activity>(null)
    private var nextRequestCode = FIRST_REQUEST_CODE

    private enum class ResultKind { KEY, PUBLIC_KEY, SIGNATURE }

    private class Operation(
        val id: String?,
        val providerPackage: String,
        val kind: ResultKind,
        val result: MethodChannel.Result,
        val messenger: BinaryMessenger?,
    ) {
        val completed = AtomicBoolean(false)
        var connection: ServiceConnection? = null
        var work: Future<*>? = null
        var deadline: Runnable? = null
        var interactionActivity = WeakReference<Activity>(null)
    }

    fun register(messenger: BinaryMessenger, context: Context) {
        if (channels.containsKey(messenger)) return
        appContext = context.applicationContext
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result -> handleCall(call, result, messenger) }
        channels[messenger] = channel
    }

    fun unregister(messenger: BinaryMessenger) {
        operations.filter { it.messenger === messenger }.toList().forEach {
            finishError(it, "openkeychain_cancelled", "The Flutter engine was detached")
        }
        channels.remove(messenger)?.setMethodCallHandler(null)
    }

    fun attachActivity(value: Activity) {
        activity = WeakReference(value)
    }

    fun detachActivity(value: Activity) {
        if (activity.get() === value) activity.clear()
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) =
        handleCall(call, result, null)

    private fun handleCall(call: MethodCall, result: MethodChannel.Result, messenger: BinaryMessenger?) {
        when (call.method) {
            "listProviders" -> result.success(listProviders())
            "cancel" -> {
                val id = requiredString(call, "operationId", result) ?: return
                operations.filter { it.id == id }.toList().forEach {
                    finishError(it, "openkeychain_cancelled", "OpenKeychain request was cancelled")
                }
                result.success(null)
            }
            "selectKey" -> {
                val operation = operation(call, ResultKind.KEY, result, messenger) ?: return
                execute(operation, Intent(SshAuthenticationApi.ACTION_SELECT_KEY))
            }
            "getSshPublicKey" -> {
                val keyId = requiredString(call, "keyId", result) ?: return
                val operation = operation(call, ResultKind.PUBLIC_KEY, result, messenger) ?: return
                execute(
                    operation,
                    Intent(SshAuthenticationApi.ACTION_GET_SSH_PUBLIC_KEY).apply {
                        putExtra(SshAuthenticationApi.EXTRA_KEY_ID, keyId)
                    },
                )
            }
            "sign" -> {
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
                val operation = operation(call, ResultKind.SIGNATURE, result, messenger) ?: return
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
        messenger: BinaryMessenger?,
    ): Operation? {
        val provider = requiredString(call, "providerPackage", result) ?: return null
        val operation = Operation(call.argument<String>("operationId"), provider, kind, result, messenger)
        operations.add(operation)
        operation.deadline = Runnable {
            finishError(operation, "openkeychain_timeout", "The key provider did not respond within two minutes. Try again.")
        }.also { mainHandler.postDelayed(it, 120_000) }
        return operation
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

    private fun unbind(operation: Operation) {
        val connection = operation.connection ?: return
        operation.connection = null
        try {
            appContext.unbindService(connection)
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun execute(operation: Operation, request: Intent) {
        if (operation.completed.get()) return
        val serviceIntent = Intent(SshAuthenticationApi.SERVICE_INTENT).apply {
            setPackage(operation.providerPackage)
        }
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                if (operation.completed.get()) return
                try {
                    operation.work = worker.submit {
                        if (operation.completed.get()) return@submit
                        try {
                            val service = ISshAuthenticationService.Stub.asInterface(binder)
                            val response = SshAuthenticationApi(appContext, service).executeApi(request)
                            mainHandler.post {
                                unbind(operation)
                                operation.work = null
                                if (!operation.completed.get()) processResponse(operation, response)
                            }
                        } catch (error: Exception) {
                            mainHandler.post {
                                finishError(operation, "openkeychain_error", "OpenKeychain request failed: ${error.message}")
                            }
                        }
                    }
                } catch (_: RejectedExecutionException) {
                    finishError(operation, "openkeychain_busy", "The key provider is still unresponsive. Restart the provider, then try again.")
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                finishError(operation, "openkeychain_disconnected", "The OpenKeychain provider disconnected")
            }

            override fun onBindingDied(name: ComponentName) {
                finishError(operation, "openkeychain_disconnected", "The OpenKeychain provider disconnected")
            }

            override fun onNullBinding(name: ComponentName) {
                finishError(operation, "openkeychain_unavailable", "The selected OpenKeychain provider is unavailable")
            }
        }
        val bound = try {
            appContext.bindService(serviceIntent, connection, Context.BIND_AUTO_CREATE)
        } catch (_: SecurityException) {
            false
        }
        if (bound) {
            operation.connection = connection
        } else {
            finishError(operation, "openkeychain_unavailable", "The selected OpenKeychain provider is not installed or cannot be opened")
        }
    }

    private fun processResponse(operation: Operation, response: Intent) {
        if (operation.completed.get()) return
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
                        "Open this app to approve the OpenKeychain request",
                    )
                } else {
                    if (nextRequestCode > 65000) nextRequestCode = FIRST_REQUEST_CODE
                    val requestCode = nextRequestCode++
                    interactions[requestCode] = operation
                    operation.interactionActivity = WeakReference(currentActivity)
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
        operation.interactionActivity.clear()
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

    private fun cleanup(operation: Operation) {
        operations.remove(operation)
        operation.deadline?.let { mainHandler.removeCallbacks(it) }
        operation.deadline = null
        val requestCodes = interactions.filterValues { it === operation }.keys.toList()
        for (requestCode in requestCodes) {
            interactions.remove(requestCode)
            operation.interactionActivity.get()?.finishActivity(requestCode)
        }
        operation.interactionActivity.clear()
        unbind(operation)
        operation.work?.cancel(true)
        operation.work = null
    }

    private fun finishSuccess(operation: Operation, value: Any) {
        if (operation.completed.compareAndSet(false, true)) {
            cleanup(operation)
            operation.result.success(value)
        }
    }

    private fun finishError(
        operation: Operation,
        code: String,
        message: String,
        details: Any? = null,
    ) {
        if (operation.completed.compareAndSet(false, true)) {
            cleanup(operation)
            operation.result.error(code, message, details)
        }
    }
}
