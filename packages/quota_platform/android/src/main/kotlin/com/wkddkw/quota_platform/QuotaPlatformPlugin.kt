package com.wkddkw.quota_platform

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject

/** Registered in foreground and WorkManager Flutter engines; no network or keys. */
class QuotaPlatformPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    @Volatile private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var permissionReply: MethodChannel.Result? = null
    companion object {
        private val lock = Any()
        private const val PERMISSION_REQUEST = 4172
        private const val PREFS = "quota_monitor"
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val messenger = binding.binaryMessenger
        channel = MethodChannel(messenger, "com.wkddkw.cliproxy_quota/cache", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { channel.setMethodCallHandler(null) }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding; activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { detachActivity(false) }
    override fun onDetachedFromActivity() { detachActivity(true) }
    private fun detachActivity(permanent: Boolean) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null; activity = null
        if (permanent) { permissionReply?.success(false); permissionReply = null }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionReply?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        permissionReply = null
        return true
    }
    private fun monitor() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun config() = try { JSONObject(monitor().getString("config", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
    private fun notifications() = QuotaNotifications(context).apply { channels() }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "appVersion" -> result.success(AppUpdates(context).version())
                "startUpdate" -> result.success(AppUpdates(context).start(call.arguments as Map<*, *>))
                "updateStatus" -> result.success(AppUpdates(context).status())
                "cancelUpdate" -> { AppUpdates(context).cancel(); result.success(null) }
                "installUpdate" -> {
                    val current = activity
                    if (current == null) { result.error("NO_ACTIVITY", "请打开 App 安装更新", null); return }
                    val (state, intent) = AppUpdates(context).installIntent()
                    current.runOnUiThread {
                        try { current.startActivity(intent); result.success(state) }
                        catch (_: Exception) { result.error("INSTALL_OPEN", "无法打开系统安装页面", null) }
                    }
                }
                "openBatterySettings" -> launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), result)
                "openNotificationSettings" -> launch(if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName) else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")), result)
                "notificationStatus" -> result.success(notificationStatus())
                "requestNotificationPermission" -> {
                    val current = activity
                    if (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) result.success(notifications().alertsAllowed())
                    else if (current == null) result.error("NO_ACTIVITY", "请在 App 设置页申请通知权限", null)
                    else current.runOnUiThread {
                        if (permissionReply != null) result.error("PERMISSION_BUSY", "通知权限请求正在进行", null)
                        else { permissionReply = result; current.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST) }
                    }
                }
                "testNotification" -> synchronized(lock) { result.success(notifications().test()) }
                "configureMonitoring" -> synchronized(lock) {
                    val incoming = JSONObject(call.arguments as String)
                    val old = config()
                    val threshold = incoming.optDouble("threshold", 5.0)
                    require(threshold.isFinite() && threshold in 1.0..100.0)
                    val reset = old.optBoolean("enabled") != incoming.optBoolean("enabled") || old.optDouble("threshold", 5.0) != threshold || old.optString("mode", "delta") != incoming.optString("mode", "delta")
                    val edit = monitor().edit().putString("config", incoming.toString())
                    if (reset) edit.remove("anchors").remove("observedMillis")
                    if (!incoming.optBoolean("enabled")) edit.putBoolean("checking", false)
                    edit.commit()
                    LegacyMonitoring.retire(context)
                    val n = notifications()
                    if (!incoming.optBoolean("enabled") || old.optBoolean("hideDetails") != incoming.optBoolean("hideDetails")) n.cancelAll()
                    result.success(null)
                }
                "setConnectionEpoch" -> synchronized(lock) {
                    val epoch = call.arguments as String
                    if (monitor().getString("epoch", "") != epoch) {
                        monitor().edit().putString("epoch", epoch).remove("anchors").remove("observedMillis").remove("lastError").remove("lastCheck").remove("lastBackgroundCheck").remove("lastBackgroundError").remove("backgroundStarted").putBoolean("checking", false).commit()
                        context.getSharedPreferences("quota_cache", Context.MODE_PRIVATE).edit().clear().commit()
                        notifications().cancelAll()
                    }
                    result.success(null)
                }
                "monitoringStatus" -> synchronized(lock) {
                    result.success(notificationStatus() + mapOf("lastCheck" to monitor().getLong("lastCheck", 0), "lastError" to monitor().getString("lastError", ""),
                        "enabled" to config().optBoolean("enabled"),
                        "activityVisible" to (activity?.hasWindowFocus() == true),
                        "lastBackgroundCheck" to monitor().getLong("lastBackgroundCheck", 0),
                        "lastBackgroundError" to monitor().getString("lastBackgroundError", ""),
                        "checking" to monitor().getBoolean("checking", false),
                        "periodicIntervals" to androidx.work.WorkManager.getInstance(context).getWorkInfosForUniqueWork("quota-monitor-v1").get(5, java.util.concurrent.TimeUnit.SECONDS).filter { !it.state.isFinished }.map { it.periodicityInfo?.repeatIntervalMillis ?: 0L },
                        "overviewVisible" to context.getSystemService(android.app.NotificationManager::class.java).activeNotifications.any { it.id == QuotaNotifications.STATUS_ID },
                        "overviewOngoing" to context.getSystemService(android.app.NotificationManager::class.java).activeNotifications.any { it.id == QuotaNotifications.STATUS_ID && (it.notification.flags and android.app.Notification.FLAG_ONGOING_EVENT) != 0 },
                        "alertsVisible" to context.getSystemService(android.app.NotificationManager::class.java).activeNotifications.count { it.id >= 7200 },
                        "batteryOptimized" to !context.getSystemService(android.os.PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)))
                }
                "backgroundStarted" -> synchronized(lock) {
                    val args = call.arguments as Map<*, *>
                    if (monitor().getString("epoch", "") == args["epoch"] && config().optBoolean("enabled")) {
                        monitor().edit().putLong("backgroundStarted", System.currentTimeMillis()).putBoolean("checking", true).commit()
                    }
                    result.success(null)
                }
                "backgroundFailure" -> synchronized(lock) {
                    if (monitor().getString("epoch", "") == call.arguments && config().optBoolean("enabled")) {
                        monitor().edit().putLong("lastCheck", System.currentTimeMillis()).putLong("lastBackgroundCheck", System.currentTimeMillis()).putBoolean("checking", false).putString("lastBackgroundError", "后台查询失败，请检查服务器与 VPN").putString("lastError", "检查失败，保留上次结果；请检查服务器与 VPN").apply()
                    }
                    result.success(null)
                }
                "writeCache", "writeBackgroundCache" -> synchronized(lock) {
                    val args = call.arguments as Map<*, *>
                    val background = call.method != "writeCache"
                    if (monitor().getString("epoch", "") != args["epoch"] || (background && !config().optBoolean("enabled"))) {
                        result.success(false); return
                    }
                    val data = JSONObject(args["snapshot"] as String)
                    if (background) recordBackground(data)
                    val observed = data.optLong("observedMillis", 0)
                    if (observed <= monitor().getLong("observedMillis", 0)) { result.success(false); return }
                    val written = context.getSharedPreferences("quota_cache", Context.MODE_PRIVATE).edit().putString("snapshot", data.toString()).commit()
                    if (!written) { result.error("CACHE_WRITE", "无法写入本机缓存", null); return }
                    process(data)
                    result.success(true)
                }
                "clearCache" -> synchronized(lock) {
                    context.getSharedPreferences("quota_cache", Context.MODE_PRIVATE).edit().clear().commit()
                    monitor().edit().remove("anchors").remove("observedMillis").remove("lastError").remove("lastCheck").remove("lastBackgroundCheck").remove("lastBackgroundError").remove("backgroundStarted").putBoolean("checking", false).commit()
                    notifications().cancelAll()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("QUOTA_PLATFORM", if (call.method in listOf("startUpdate", "installUpdate", "cancelUpdate")) error.message ?: "更新操作失败" else error.javaClass.simpleName, null) }
    }
    private fun notificationStatus(): Map<String, Any> {
        val n = notifications()
        return mapOf("allowed" to n.alertsAllowed())
    }
    private fun launch(intent: Intent, result: MethodChannel.Result) {
        val current = activity
        if (current == null) { result.error("NO_ACTIVITY", "请在 App 中打开", null); return }
        current.runOnUiThread {
            try { current.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(null) }
            catch (error: Exception) { result.error("OPEN_SETTINGS", error.javaClass.simpleName, null) }
        }
    }
    private fun recordBackground(data: JSONObject) {
            val rows = data.optJSONArray("providers")
            var issues = 0
            if (rows != null) for (i in 0 until rows.length()) issues += rows.optJSONObject(i)?.optInt("issues") ?: 0
            monitor().edit().putLong("lastBackgroundCheck", System.currentTimeMillis()).putBoolean("checking", false)
                .putString("lastBackgroundError", if (issues > 0) "部分账号查询失败，请打开 App 查看明细" else "").commit()
    }
    private fun process(data: JSONObject) {
        val c = config()
        val stamp = data.optLong("observedMillis")
        monitor().edit().putLong("observedMillis", stamp).putLong("lastCheck", System.currentTimeMillis()).remove("lastError").commit()
        if (!c.optBoolean("enabled")) return
        val previous = try { JSONObject(monitor().getString("anchors", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
        val anchors = mutableMapOf<String, QuotaAnchor>()
        previous.keys().forEach { name ->
            val row = previous.optJSONObject(name)
            if (row != null) {
                val a = row.optDouble("anchor"); val p = row.optDouble("previous")
                if (a.isFinite() && p.isFinite()) anchors[name] = QuotaAnchor(a, p, row.optString("cycle"))
            }
        }
        val rows = data.optJSONArray("samples") ?: data.optJSONArray("providers")
        val samples = mutableListOf<QuotaSample>()
        if (rows != null) for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            samples += QuotaSample(row.optString("name"), row.optDouble("remaining").takeIf { it.isFinite() }, row.optString("cycle"), row.optInt("issues") == 0, row.optString("label", row.optString("name")))
        }
        val n = notifications()
        val evaluated = QuotaTracker.evaluate(samples, anchors, c.optDouble("threshold", 5.0), c.optString("mode", "delta"), n.alertsAllowed())
        val states = evaluated.anchors.toMutableMap()
        for (change in evaluated.changes) {
            if (!n.alert(change, c.optBoolean("hideDetails"))) {
                val old = anchors[change.name]
                if (old != null) states[change.name] = states.getValue(change.name).copy(anchor = old.anchor)
            }
        }
        val saved = JSONObject()
        states.forEach { (name, a) -> saved.put(name, JSONObject().put("anchor", a.anchor).put("previous", a.previous).put("cycle", a.cycle)) }
        monitor().edit().putString("anchors", saved.toString()).commit()
    }
}
