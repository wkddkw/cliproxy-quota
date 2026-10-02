package com.wkddkw.cliproxy_quota

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.content.pm.PackageManager
import android.widget.RemoteViews
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.wkddkw.cliproxy_quota/cache")
            .setMethodCallHandler { call, result ->
                val manager = AppWidgetManager.getInstance(this)
                if (call.method == "widgetStatus") {
                    val provider = ComponentName(this, QuotaWidgetProvider::class.java)
                    val home = packageManager.resolveActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME), PackageManager.MATCH_DEFAULT_ONLY)
                    result.success(mapOf(
                        "pinSupported" to (Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported),
                        "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "androidVersion" to Build.VERSION.RELEASE,
                        "apiLevel" to Build.VERSION.SDK_INT,
                        "launcher" to (home?.activityInfo?.packageName ?: "未知"),
                        "providerRegistered" to manager.installedProviders.any { it.provider == provider },
                        "widgetCount" to manager.getAppWidgetIds(provider).size
                    ))
                    return@setMethodCallHandler
                }
                if (call.method == "pinWidget") {
                    if (Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported) {
                        val preview = Bundle().apply {
                            putParcelable(AppWidgetManager.EXTRA_APPWIDGET_PREVIEW, RemoteViews(packageName, R.layout.quota_widget))
                        }
                        try {
                            result.success(manager.requestPinAppWidget(ComponentName(this, QuotaWidgetProvider::class.java), preview, null))
                        } catch (error: Exception) {
                            result.error("WIDGET_PIN", error.javaClass.simpleName, null)
                        }
                    } else { result.success(false) }
                    return@setMethodCallHandler
                }
                if (call.method == "openHome") {
                    startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                    return@setMethodCallHandler
                }
                val cache = getSharedPreferences("quota_widget", MODE_PRIVATE)
                val success = when (call.method) {
                    "writeCache" -> cache.edit().putString("snapshot", call.arguments as String).commit()
                    "clearCache" -> cache.edit().clear().commit()
                    else -> { result.notImplemented(); return@setMethodCallHandler }
                }
                if (success) {
                    QuotaWidgetProvider.updateAll(this)
                    result.success(null)
                } else {
                    result.error("CACHE_WRITE", "无法写入小组件缓存", null)
                }
            }
    }
}
