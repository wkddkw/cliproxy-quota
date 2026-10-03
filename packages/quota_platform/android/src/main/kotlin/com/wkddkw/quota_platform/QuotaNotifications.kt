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
    fun monitorNotification(running: Boolean): Notification {
        val state = context.getSharedPreferences("quota_monitor", Context.MODE_PRIVATE)
        val c = try { JSONObject(state.getString("config", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
        val hide = c.optBoolean("hideDetails")
        val data = try { JSONObject(context.getSharedPreferences("quota_cache", Context.MODE_PRIVATE).getString("snapshot", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
        val providers = data.optJSONArray("providers")
        val lines = mutableListOf<String>()
        if (!hide && providers != null) for (i in 0 until providers.length()) {
            val p = providers.optJSONObject(i) ?: continue
            val pct = p.optDouble("remaining")
            lines += "${p.optString("name")}：${if (pct.isFinite()) "${format(pct)}%" else "查询失败 / 未提供"}"
        }
        val last = state.getLong("lastBackgroundCheck", 0)
        val next = state.getLong("nextCheck", 0)
        val checking = running && state.getBoolean("checking", false)
        val title = if (running) "CLIProxy 常驻监测" else "CLIProxy 系统定期检查"
        val body = if (hide) "监测已开启，打开 App 查看" else lines.joinToString(" · ").ifEmpty { "正在建立限额基准" }
        val b = builder(STATUS_CHANNEL, title, body).setOnlyAlertOnce(true).setOngoing(true).setAutoCancel(false)
        val time = if (last > 0) "最近后台检查：${time(last)}" else "尚未完成后台检查"
        val progress = if (checking) "正在查询限额" else if (running && next > 0 && next < System.currentTimeMillis()) "计划已延迟：${time(next)}，等待系统唤醒" else if (running && next > 0) "下次计划：${time(next)}" else "由系统安排下次检查"
        b.setStyle(Notification.InboxStyle().apply {
            lines.forEach { addLine(it) }
            addLine(time); addLine(progress)
            if (running) addLine(if (state.getString("alarmMode", "") == "exact") "已启用精确唤醒" else "系统可延迟检查，请在 App 允许闹钟和提醒")
            val error = state.getString("lastBackgroundError", "").orEmpty()
            if (error.isNotEmpty()) addLine(error)
            if (!running) addLine(state.getString("serviceError", "常驻服务未运行，打开 App 恢复").orEmpty())
            setSummaryText("约每 ${c.optInt("interval", 15)} 分钟 · 打开 App 查看")
        })
        b.setSubText(if (checking) "正在后台检查" else time)
            .setWhen(if (last > 0) last else System.currentTimeMillis()).setShowWhen(true)
            .setDefaults(0).setSound(null).setPriority(Notification.PRIORITY_LOW)
        if (running) {
            val refresh = PendingIntent.getService(context, 7178, android.content.Intent(context, QuotaMonitorService::class.java).setAction(QuotaMonitorService.CHECK), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            b.addAction(Notification.Action.Builder(R.drawable.ic_quota_notification, "立即检查", refresh).build())
        }
        val stop = PendingIntent.getService(context, 7179, android.content.Intent(context, QuotaMonitorService::class.java).setAction(QuotaMonitorService.STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        b.addAction(Notification.Action.Builder(R.drawable.ic_quota_notification, "停止监测", stop).build())
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return b.build()
    }
    fun monitorSummary(running: Boolean) {
        if (!statusAllowed()) return
        try { manager.notify(STATUS_ID, monitorNotification(running)) } catch (_: SecurityException) {}
    }
    private fun time(millis: Long): String = java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault()).format(java.util.Date(millis))
    fun hideSummary() { manager.cancel(STATUS_ID) }
    fun cancelAll() {
        hideSummary(); manager.cancel(7199)
        records.getStringSet("alertIds", emptySet())?.forEach { it.toIntOrNull()?.let(manager::cancel) }
        records.edit().remove("alertIds").apply()
    }
    private fun format(value: Double): String = if (value == value.toInt().toDouble()) value.toInt().toString() else String.format(java.util.Locale.US, "%.1f", value)
}
