package com.example.offline_bridge

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews

class SosWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        const val ACTION_TRIGGER_SOS = "com.example.offline_bridge.ACTION_TRIGGER_SOS"
        const val ACTION_TRIGGER_SIREN = "com.example.offline_bridge.ACTION_TRIGGER_SIREN"

        fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.sos_widget)

            val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            // Intent for SOS Button
            val sosIntent = Intent(context, MainActivity::class.java).apply {
                action = ACTION_TRIGGER_SOS
                putExtra("action_type", "sos")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val sosPendingIntent = PendingIntent.getActivity(context, 1001, sosIntent, pendingIntentFlags)
            views.setOnClickPendingIntent(R.id.btn_sos_widget, sosPendingIntent)

            // Intent for Siren Button
            val sirenIntent = Intent(context, MainActivity::class.java).apply {
                action = ACTION_TRIGGER_SIREN
                putExtra("action_type", "siren")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val sirenPendingIntent = PendingIntent.getActivity(context, 1002, sirenIntent, pendingIntentFlags)
            views.setOnClickPendingIntent(R.id.btn_siren_widget, sirenPendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
