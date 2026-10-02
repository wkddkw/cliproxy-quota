package com.wkddkw.quota_platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.Color
import android.os.Build
import org.json.JSONObject

class QuotaNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val records = context.getSharedPreferences("quota_notifications", Context.MODE_PRIVATE)
    companion object {
        const val ALERT_CHANNEL = "quota_consumption_alerts"
        const val STATUS_CHANNEL = "quota_status"
        const val STATUS_ID = 7100
    }
    fun channels() {
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(ALERT_CHANNEL, "限额消耗提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "达到用户设置的消耗百分比时提醒"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            })
            manager.createNotificationChannel(NotificationChannel(STATUS_CHANNEL, "通知栏限额概览", NotificationManager.IMPORTANCE_LOW).apply {
                description = "静默显示最近检查的限额，可在 App 中隐藏"
                setSound(null, null)
            })
        }
    }
    fun alertsAllowed(): Boolean = manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(ALERT_CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    fun statusAllowed(): Boolean = manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(STATUS_CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
    private fun builder(channel: String, title: String, body: String): Notification.Builder {
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        b.setSmallIcon(R.drawable.ic_quota_notification).setContentTitle(title).setContentText(body)
            .setColor(Color.rgb(35, 132, 107)).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion((if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context))
                .setSmallIcon(R.drawable.ic_quota_notification).setContentTitle("CLIProxy 限额").setContentText("打开 App 查看限额").build())
        if (launch != null) b.setContentIntent(PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        return b
    }
    fun alert(change: QuotaChange, hide: Boolean): Boolean {
        if (!alertsAllowed()) return false
        val title = if (hide) "CLIProxy 限额提醒" else "${change.name} 限额消耗提醒"
        val body = if (hide) "限额发生变化，打开 App 查看" else "剩余 ${format(change.remaining)}% · 较上次提醒基准下降 ${format(change.consumed)} 个百分点"
        val id = 7200 + (change.name.hashCode() and 0x7fffffff) % 1000000
        return try {
            val b = builder(ALERT_CHANNEL, title, body).setAutoCancel(true).setOngoing(false)
            if (Build.VERSION.SDK_INT < 26) b.setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL)
            manager.notify(id, b.build())
            records.edit().putStringSet("alertIds", (records.getStringSet("alertIds", emptySet()) ?: emptySet()).toMutableSet().apply { add(id.toString()) }).apply()
            true
        } catch (_: SecurityException) { false }
    }
    fun test(): Boolean {
        if (!alertsAllowed()) return false
        return try {
            val b = builder(ALERT_CHANNEL, "CLIProxy 通知测试", "测试成功。悬浮显示、声音由系统通知设置控制。").setAutoCancel(true)
            if (Build.VERSION.SDK_INT < 26) b.setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL)
            manager.notify(7199, b.build()); true
        } catch (_: SecurityException) { false }
    }
    fun summary(data: JSONObject, hide: Boolean, failed: Boolean = false) {
        if (!statusAllowed()) return
        val providers = data.optJSONArray("providers")
        val lines = mutableListOf<String>()
        if (providers != null) for (i in 0 until providers.length()) {
            val p = providers.optJSONObject(i) ?: continue
            val pct = p.optDouble("remaining")
            lines += "${p.optString("name")}：${if (pct.isFinite()) "${format(pct)}%" else "未提供"}"
        }
        val text = if (hide) "限额概览已更新，打开 App 查看" else lines.joinToString(" · ").ifEmpty { "暂无支持限额的供应商" }
        val b = builder(STATUS_CHANNEL, "CLIProxy 限额概览", text).setOnlyAlertOnce(true).setOngoing(false).setShowWhen(true).setWhen(data.optLong("observedMillis", System.currentTimeMillis()))
        if (!hide) b.setStyle(Notification.InboxStyle().apply { lines.forEach { addLine(it) }; setSummaryText("最近检查结果，非实时；点击打开 App") })
        b.setDefaults(0).setSound(null).setPriority(Notification.PRIORITY_LOW)
        if (failed) b.setSubText("最近检查失败，显示缓存")
        try { manager.notify(STATUS_ID, b.build()) } catch (_: SecurityException) {}
    }
    fun hideSummary() { manager.cancel(STATUS_ID) }
    fun cancelAll() {
        hideSummary(); manager.cancel(7199)
        records.getStringSet("alertIds", emptySet())?.forEach { it.toIntOrNull()?.let(manager::cancel) }
        records.edit().remove("alertIds").apply()
    }
    private fun format(value: Double): String = if (value == value.toInt().toDouble()) value.toInt().toString() else String.format(java.util.Locale.US, "%.1f", value)
}
