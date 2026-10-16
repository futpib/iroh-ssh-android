package io.github.futpib.openkeychain_ssh

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.PluginRegistry

/** Android client for the OpenKeychain-compatible SSH authentication service. */
class OpenkeychainSshPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private var messenger: BinaryMessenger? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var activityCallbacks: Application.ActivityLifecycleCallbacks? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger = binding.binaryMessenger
        OpenKeychainBridge.register(binding.binaryMessenger, binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        messenger?.let(OpenKeychainBridge::unregister)
        messenger = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
        val currentActivity = binding.activity
        OpenKeychainBridge.attachActivity(currentActivity)
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {
                if (activity === currentActivity) OpenKeychainBridge.attachActivity(activity)
            }
            override fun onActivityPaused(activity: Activity) {
                if (activity === currentActivity) OpenKeychainBridge.detachActivity(activity)
            }
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        currentActivity.application.registerActivityLifecycleCallbacks(callbacks)
        activityCallbacks = callbacks
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        val binding = activityBinding ?: return
        binding.removeActivityResultListener(this)
        activityCallbacks?.let(binding.activity.application::unregisterActivityLifecycleCallbacks)
        activityCallbacks = null
        OpenKeychainBridge.detachActivity(binding.activity)
        activityBinding = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        OpenKeychainBridge.handleActivityResult(requestCode, resultCode, data)
}
