package com.example.offline_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SosBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            SosLockscreenService.start(context)
            NotificationHelper.showLockscreenSosNotification(context)
        }
    }
}
