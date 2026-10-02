package com.wkddkw.cliproxy_quota

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
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
                    result.success(mapOf(
                        "pinSupported" to (Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported),
                        "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "androidVersion" to Build.VERSION.RELEASE
                    ))
                    return@setMethodCallHandler
                }
                if (call.method == "pinWidget") {
                    if (Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported) {
                        result.success(manager.requestPinAppWidget(ComponentName(this, QuotaWidgetProvider::class.java), null, null))
                    } else { result.success(false) }
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
