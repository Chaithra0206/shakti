package com.example.offline_bridge

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.offline_bridge/emergency_actions"
    private var methodChannel: MethodChannel? = null
    private var pendingAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Enable activity to appear over the lockscreen and turn the screen on
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Start persistent lock screen emergency SOS service
        SosLockscreenService.start(applicationContext)
        NotificationHelper.showLockscreenSosNotification(applicationContext)

        extractActionFromIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        extractActionFromIntent(intent)
        dispatchPendingActionIfReady()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "showLockscreenNotification" -> {
                    SosLockscreenService.start(applicationContext)
                    NotificationHelper.showLockscreenSosNotification(applicationContext)
                    result.success(true)
                }
                "getInitialAction" -> {
                    val action = pendingAction
                    pendingAction = null
                    result.success(action)
                }
                "pinSosWidget" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val appWidgetManager = getSystemService(android.appwidget.AppWidgetManager::class.java)
                        val provider = android.content.ComponentName(this, SosWidgetProvider::class.java)
                        if (appWidgetManager != null && appWidgetManager.isRequestPinAppWidgetSupported) {
                            appWidgetManager.requestPinAppWidget(provider, null, null)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        dispatchPendingActionIfReady()
    }

    private fun extractActionFromIntent(intent: Intent?) {
        if (intent == null) return
        val actionType = intent.getStringExtra("action_type")
        if (actionType != null) {
            pendingAction = actionType
        } else if (intent.action == SosWidgetProvider.ACTION_TRIGGER_SOS) {
            pendingAction = "sos"
        } else if (intent.action == SosWidgetProvider.ACTION_TRIGGER_SIREN) {
            pendingAction = "siren"
        }
    }

    private fun dispatchPendingActionIfReady() {
        val action = pendingAction
        if (action != null && methodChannel != null) {
            methodChannel?.invokeMethod("onEmergencyTrigger", action)
            pendingAction = null
        }
    }
}
