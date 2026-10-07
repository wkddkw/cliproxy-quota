package com.wkddkw.quota_platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/** Remove the service, alarm and overview installed by older versions. */
object LegacyMonitoring {
    fun retire(context: Context) {
        context.stopService(Intent().setClassName(context.packageName, "com.wkddkw.quota_platform.QuotaMonitorService"))
        val alarm = PendingIntent.getBroadcast(context, 7180,
            Intent().setClassName(context.packageName, "com.wkddkw.quota_platform.QuotaCheckReceiver"),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
        if (alarm != null) { context.getSystemService(AlarmManager::class.java).cancel(alarm); alarm.cancel() }
        val state = context.getSharedPreferences("quota_monitor", Context.MODE_PRIVATE)
        val edit = state.edit().remove("nextCheck").remove("nextElapsed").remove("alarmMode").remove("serviceError")
        if (state.contains("alarmMode") || state.contains("serviceError")) edit.putBoolean("checking", false)
        edit.commit()
        QuotaNotifications(context).hideSummary()
    }
}
