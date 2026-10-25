package com.example.offline_bridge

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

class SosLockscreenService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = NotificationHelper.buildLockscreenSosNotification(this)
            startForeground(NotificationHelper.NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return START_STICKY
    }

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, SosLockscreenService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                NotificationHelper.showLockscreenSosNotification(context)
            }
        }

        fun stop(context: Context) {
            try {
                val intent = Intent(context, SosLockscreenService::class.java)
                context.stopService(intent)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}
