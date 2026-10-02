package com.wkddkw.cliproxy_quota

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Only reads sanitized local provider summaries. No keys or network clients. */
class QuotaWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { render(context, manager, it) }
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        render(context, manager, id)
    }
    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, QuotaWidgetProvider::class.java))
                .forEach { render(context, manager, it) }
        }
        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.quota_widget)
            val launch = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_root, launch)
            views.removeAllViews(R.id.widget_rows)
            val raw = context.getSharedPreferences("quota_widget", Context.MODE_PRIVATE).getString("snapshot", null)
            val data = try { raw?.let { JSONObject(it) } } catch (_: Exception) { null }
            val providers = data?.optJSONArray("providers")
            val count = providers?.length() ?: 0
            views.setViewVisibility(R.id.widget_empty, if (count == 0) View.VISIBLE else View.GONE)
            views.setTextViewText(R.id.widget_empty, if (data == null) "打开 App 连接服务器" else "暂没有支持限额的供应商")
            val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180)
            val capacity = ((height - 64) / 54).coerceIn(1, 8)
            for (i in 0 until minOf(count, capacity)) {
                val provider = providers!!.getJSONObject(i)
                val row = RemoteViews(context.packageName, R.layout.quota_widget_row)
                row.setTextViewText(R.id.row_symbol, provider.optString("symbol", "?"))
                row.setTextViewText(R.id.row_name, provider.optString("name"))
                row.setTextViewText(R.id.row_count, "${provider.optInt("count")} 个账号")
                val remaining = if (provider.isNull("remaining")) null else provider.optDouble("remaining")
                row.setTextViewText(R.id.row_percent, remaining?.let { "${it.toInt()}%" } ?: "—")
                row.setProgressBar(R.id.row_progress, 100, remaining?.toInt() ?: 0, false)
                views.addView(R.id.widget_rows, row)
            }
            val updated = data?.optString("updatedAt") ?: ""
            val time = try {
                val parser = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
                val date = parser.parse(updated.substringBefore('.').removeSuffix("Z")) ?: Date()
                SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(date)
            } catch (_: Exception) { "尚未刷新" }
            views.setTextViewText(R.id.widget_updated, if (data == null) "尚未刷新" else "更新于 $time${if (count > capacity) " · 更多见 App" else ""}")
            manager.updateAppWidget(id, views)
        }
    }
}
