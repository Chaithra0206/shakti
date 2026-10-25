package com.example.offline_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.widget.RemoteViews

object NotificationHelper {

    const val CHANNEL_ID = "emergency_sos_channel"
    const val CHANNEL_NAME = "🚨 Emergency SOS Lock Screen Widget"
    const val NOTIFICATION_ID = 9991

    fun buildLockscreenSosNotification(context: Context): Notification {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Always-on 1-Tap SOS and Siren widget on lock screen"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableLights(true)
                lightColor = Color.RED
                enableVibration(false)
                setShowBadge(false)
                setSound(null, null)
            }
            manager.createNotificationChannel(channel)
        }

        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        // Tap notification body -> Open app
        val contentIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val contentPendingIntent = PendingIntent.getActivity(context, 2000, contentIntent, pendingIntentFlags)

        // Action 1: Send SOS
        val sosIntent = Intent(context, MainActivity::class.java).apply {
            action = SosWidgetProvider.ACTION_TRIGGER_SOS
            putExtra("action_type", "sos")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val sosPendingIntent = PendingIntent.getActivity(context, 2001, sosIntent, pendingIntentFlags)

        // Action 2: Siren
        val sirenIntent = Intent(context, MainActivity::class.java).apply {
            action = SosWidgetProvider.ACTION_TRIGGER_SIREN
            putExtra("action_type", "siren")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val sirenPendingIntent = PendingIntent.getActivity(context, 2002, sirenIntent, pendingIntentFlags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        // Custom Widget-style RemoteViews layout for Lock Screen
        val widgetView = RemoteViews(context.packageName, R.layout.sos_widget)
        widgetView.setOnClickPendingIntent(R.id.btn_sos_widget, sosPendingIntent)
        widgetView.setOnClickPendingIntent(R.id.btn_siren_widget, sirenPendingIntent)

        builder.setSmallIcon(R.drawable.ic_sos_tile)
            .setContentTitle("🚨 SHAKTI EMERGENCY SOS")
            .setContentText("Direct Lock Screen Fast Access: Tap [SEND SOS] or [SIREN]")
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_MAX)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setCategory(Notification.CATEGORY_ALARM)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            builder.setCustomBigContentView(widgetView)
            builder.setCustomContentView(widgetView)
        }

        // Standard 1-tap lockscreen action buttons fallback
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

        return builder.build()
    }

    fun showLockscreenSosNotification(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        try {
            val notification = buildLockscreenSosNotification(context)
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
