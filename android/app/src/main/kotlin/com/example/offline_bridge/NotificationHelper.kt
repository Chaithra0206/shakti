package com.example.offline_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build

object NotificationHelper {

    private const val CHANNEL_ID = "emergency_sos_channel"
    private const val CHANNEL_NAME = "🚨 Emergency SOS Service"
    private const val NOTIFICATION_ID = 9991

    fun showLockscreenSosNotification(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Quick emergency actions visible on lockscreen"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableLights(true)
                lightColor = Color.RED
                enableVibration(false)
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        // Tap notification body -> Open app
        val contentIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(context, 2000, contentIntent, flags)

        // Action 1: Send SOS
        val sosIntent = Intent(context, MainActivity::class.java).apply {
            action = SosWidgetProvider.ACTION_TRIGGER_SOS
            putExtra("action_type", "sos")
            this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val sosPendingIntent = PendingIntent.getActivity(context, 2001, sosIntent, flags)

        // Action 2: Siren
        val sirenIntent = Intent(context, MainActivity::class.java).apply {
            action = SosWidgetProvider.ACTION_TRIGGER_SIREN
            putExtra("action_type", "siren")
            this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val sirenPendingIntent = PendingIntent.getActivity(context, 2002, sirenIntent, flags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder.setSmallIcon(R.drawable.ic_sos_tile)
            .setContentTitle("🚨 Shakti Offline SOS Bridge")
            .setContentText("Emergency Fast Access: Tap to broadcast SOS or trigger siren")
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_MAX)

        // Add 1-tap lockscreen action buttons
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val sosAction = Notification.Action.Builder(
                null,
                "🚨 SEND SOS",
                sosPendingIntent
            ).build()

            val sirenAction = Notification.Action.Builder(
                null,
                "🔊 SIREN",
                sirenPendingIntent
            ).build()

            builder.addAction(sosAction)
            builder.addAction(sirenAction)
        } else {
            @Suppress("DEPRECATION")
            builder.addAction(R.drawable.ic_sos_tile, "🚨 SEND SOS", sosPendingIntent)
            @Suppress("DEPRECATION")
            builder.addAction(R.drawable.ic_sos_tile, "🔊 SIREN", sirenPendingIntent)
        }

        manager.notify(NOTIFICATION_ID, builder.build())
    }
}
