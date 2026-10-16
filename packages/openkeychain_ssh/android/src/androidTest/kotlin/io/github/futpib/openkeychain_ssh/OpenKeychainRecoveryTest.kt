package io.github.futpib.openkeychain_ssh

import android.content.ComponentName
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.Looper
import androidx.test.runner.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.openintents.ssh.authentication.ISshAuthenticationService
import org.openintents.ssh.authentication.SshAuthenticationApi
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class OpenKeychainRecoveryTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var context: ProviderContext
    private val component = ComponentName("test.provider", "Service")

    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        var count = 0
        var code: String? = null
        var value: Any? = null
        override fun success(result: Any?) { count++; value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) {
            count++; this.code = code; done.countDown()
        }
        override fun notImplemented() { error("not_implemented", null, null) }
        fun await() { assertTrue("No channel reply", done.await(5, TimeUnit.SECONDS)) }
    }

    private inner class ProviderContext : ContextWrapper(instrumentation.targetContext) {
        val bindings = mutableSetOf<ServiceConnection>()
        var latest: ServiceConnection? = null
        var respond: (() -> Intent)? = null
        override fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean {
            bindings.add(connection)
            latest = connection
            respond?.let { response ->
                Handler(Looper.getMainLooper()).post {
                    connection.onServiceConnected(component, object : ISshAuthenticationService.Stub() {
                        override fun execute(intent: Intent): Intent = response()
                    })
                }
            }
            return true
        }
        override fun unbindService(connection: ServiceConnection) {
            assertTrue("Binding removed twice", bindings.remove(connection))
        }
    }

    private fun main(work: () -> Unit) = instrumentation.runOnMainSync(work)
    private fun field(name: String): Any = OpenKeychainBridge::class.java.getDeclaredField(name).let {
        it.isAccessible = true; it.get(OpenKeychainBridge)!!
    }
    private fun call(method: String, id: String = "test"): Reply {
        val reply = Reply()
        main {
            val handler = OpenKeychainBridge::class.java.getDeclaredMethod(
                "handleCall", MethodCall::class.java, MethodChannel.Result::class.java,
            ).apply { isAccessible = true }
            handler.invoke(OpenKeychainBridge, MethodCall(method, mapOf(
                "providerPackage" to "test.provider", "operationId" to id,
            )), reply)
        }
        return reply
    }
    private fun clean() = main {
        assertTrue(context.bindings.isEmpty())
        assertTrue((field("operations") as Set<*>).isEmpty())
        assertTrue((field("interactions") as Map<*, *>).isEmpty())
    }
    private fun success() = Intent().apply {
        putExtra(SshAuthenticationApi.EXTRA_RESULT_CODE, SshAuthenticationApi.RESULT_CODE_SUCCESS)
        putExtra(SshAuthenticationApi.EXTRA_KEY_ID, "123")
    }

    @Before fun setup() {
        context = ProviderContext()
        main {
            OpenKeychainBridge::class.java.getDeclaredField("appContext").apply {
                isAccessible = true; set(OpenKeychainBridge, context)
            }
        }
    }

    @Test fun cancelPendingBindingThenRetry() {
        val pending = call("selectKey")
        call("cancel").await()
        pending.await()
        assertEquals("openkeychain_cancelled", pending.code)
        clean()
        context.respond = { success() }
        val retry = call("selectKey", "retry")
        retry.await()
        assertEquals("123", (retry.value as Map<*, *>)["keyId"])
        clean()
    }

    @Test fun deadlineUnbindsAndIgnoresLateServiceConnection() {
        val pending = call("selectKey")
        val connection = context.latest!!
        main {
            val operation = (field("operations") as Set<*>).single()!!
            val deadline = operation.javaClass.getDeclaredField("deadline").apply { isAccessible = true }
            (deadline.get(operation) as Runnable).run()
            connection.onServiceConnected(component, object : ISshAuthenticationService.Stub() {
                override fun execute(intent: Intent): Intent = error("Cancelled request executed")
            })
        }
        pending.await()
        assertEquals("openkeychain_timeout", pending.code)
        clean()
    }

    @Test fun cancelledBinderReplyCannotOpenInteractionOrCompleteTwice() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val returned = CountDownLatch(1)
        context.respond = {
            started.countDown()
            while (release.count > 0) {
                try { release.await() } catch (_: InterruptedException) { /* Simulate a stuck binder. */ }
            }
            returned.countDown()
            Intent().apply {
                putExtra(SshAuthenticationApi.EXTRA_RESULT_CODE, SshAuthenticationApi.RESULT_CODE_USER_INTERACTION_REQUIRED)
            }
        }
        try {
            val pending = call("selectKey")
            assertTrue(started.await(5, TimeUnit.SECONDS))
            call("cancel").await()
            pending.await()
            clean()
            release.countDown()
            assertTrue(returned.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            main { assertEquals(1, pending.count) }
            clean()
        } finally { release.countDown() }
    }

    @Test fun cancelledInteractionCannotResumeAnOperation() {
        val pending = call("selectKey")
        main {
            // Stand in for an outstanding Android provider activity result.
            val operation = (field("operations") as Set<*>).single()!!
            @Suppress("UNCHECKED_CAST")
            val interactions = field("interactions") as MutableMap<Int, Any>
            interactions[47001] = operation
        }
        call("cancel").await()
        pending.await()
        clean()
        main {
            assertFalse(OpenKeychainBridge.handleActivityResult(47001, android.app.Activity.RESULT_OK, Intent()))
            assertEquals(1, pending.count)
        }
    }

    @Test fun providerBindingDeathCleansUp() {
        val pending = call("selectKey")
        main { context.latest!!.onBindingDied(component) }
        pending.await()
        assertEquals("openkeychain_disconnected", pending.code)
        clean()
    }
}
