package com.wkddkw.quota_platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import org.json.JSONObject

/** User-started dataSync service. Honors Android timeouts; never claims a VPN. */
class QuotaMonitorService : Service() {
    companion object {
        val controlLock = Any()
        const val STOP = "com.wkddkw.cliproxy_quota.STOP_MONITOR"
        const val CHECK = "com.wkddkw.cliproxy_quota.CHECK_QUOTA"
        @Volatile var instance: QuotaMonitorService? = null
            private set
        fun start(context: Context) {
            val intent = Intent(context, QuotaMonitorService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }
        fun stop(context: Context) { context.stopService(Intent(context, QuotaMonitorService::class.java)) }
        fun disable(context: Context) = synchronized(controlLock) {
            val state = context.getSharedPreferences("quota_monitor", MODE_PRIVATE)
            val c = try { JSONObject(state.getString("config", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
            c.put("enabled", false)
            state.edit().putString("config", c.toString()).commit()
            context.getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).edit().putString("flutter.monitoring", c.toString()).commit()
            QuotaNotifications(context).cancelAll()
            stop(context)
        }

    }
    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private var checking = false
    private var closed = false
    private var wake: PowerManager.WakeLock? = null
    private val tick = Runnable { check() }
    private val checkWatchdog = Runnable { if (checking) pause("后台查询超时，打开 App 恢复；系统定期检查继续") }
    private fun prefs() = getSharedPreferences("quota_monitor", MODE_PRIVATE)
    private fun config() = try { JSONObject(prefs().getString("config", "{}") ?: "{}") } catch (_: Exception) { JSONObject() }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        instance = this
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            disableMonitoring()
            return START_NOT_STICKY
        }
        if (!config().optBoolean("enabled")) { stopSelf(); return START_NOT_STICKY }
        val notifications = QuotaNotifications(this).apply { channels() }
        try {
            val notification = notifications.monitorNotification(true)
            if (Build.VERSION.SDK_INT >= 29) startForeground(QuotaNotifications.STATUS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(QuotaNotifications.STATUS_ID, notification)
        } catch (_: Exception) {
            prefs().edit().putString("serviceError", "系统拒绝启动常驻监测，请打开 App 检查通知与后台运行设置").commit()
            stopSelf()
            return START_NOT_STICKY
        }
        prefs().edit().remove("serviceError").putLong("serviceStarted", System.currentTimeMillis()).commit()
        if (engine == null) initializeEngine() else if (ready) check()
        // A system kill may restart the existing service. Force-stop is respected.
        return START_STICKY
    }
    private fun initializeEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, handler) {
            if (closed) return@ensureInitializationCompleteAsync
            try {
                val created = FlutterEngine(applicationContext)
                engine = created
                channel = MethodChannel(created.dartExecutor.binaryMessenger, "com.wkddkw.cliproxy_quota/service")
                channel?.setMethodCallHandler { call, reply ->
                    when (call.method) {
                        "ready" -> { ready = true; reply.success(null); check() }
                        "complete" -> {
                            checking = false
                            handler.removeCallbacks(checkWatchdog)
                            releaseWake()
                            schedule()
                            updateNotification()
                            reply.success(null)
                        }
                        else -> reply.notImplemented()
                    }
                }
                val callback = FlutterCallbackInformation.lookupCallbackInformation(config().optLong("serviceCallback"))
                    ?: throw IllegalStateException("missing service callback")
                created.dartExecutor.executeDartCallback(DartExecutor.DartCallback(assets, loader.findAppBundlePath(), callback))
                handler.postDelayed({
                    if (!ready && !closed) pause("后台查询引擎启动失败，打开 App 恢复监测")
                }, 30000)
            } catch (_: Exception) { pause("后台查询引擎启动失败，打开 App 恢复监测") }
        }
    }
    fun check() {
        if (closed || !ready || checking) return
        if (!config().optBoolean("enabled")) { stopSelf(); return }
        cancelSchedule()
        checking = true
        handler.postDelayed(checkWatchdog, 5 * 60 * 1000L)
        prefs().edit().putBoolean("checking", true).putLong("backgroundStarted", System.currentTimeMillis()).commit()
        val power = getSystemService(PowerManager::class.java)
        wake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:quota-check").apply { acquire(5 * 60 * 1000L) }
        updateNotification()
        channel?.invokeMethod("check", null, object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) { pause("后台查询异常，打开 App 恢复监测") }
            override fun notImplemented() { pause("后台查询不可用，打开 App 恢复监测") }
        })
    }
    fun reschedule() {
        handler.post { if (!closed && !checking && ready) schedule(); updateNotification() }
    }
    private fun schedule() {
        if (closed) return
        prefs().edit().putBoolean("checking", false).commit()
        val minutes = config().optInt("interval", 15).let { if (it in listOf(15, 30, 60)) it else 15 }
        val delay = minutes * 60 * 1000L
        prefs().edit().putLong("nextCheck", System.currentTimeMillis() + delay).commit()
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, delay)
        // An inexact idle alarm can wake a sleeping device. No exact-alarm permission.
        val alarm = getSystemService(AlarmManager::class.java)
        alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, android.os.SystemClock.elapsedRealtime() + delay, alarmIntent())
    }
    private fun alarmIntent() = PendingIntent.getBroadcast(this, 7180, Intent(this, QuotaCheckReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun cancelSchedule() {
        handler.removeCallbacks(tick)
        getSystemService(AlarmManager::class.java).cancel(alarmIntent())
        prefs().edit().remove("nextCheck").commit()
    }
    private fun releaseWake() { wake?.let { if (it.isHeld) it.release() }; wake = null }
    private fun updateNotification() { if (!closed) QuotaNotifications(this).monitorSummary(true) }
    fun disableMonitoring() { disable(this) }
    private fun pause(message: String) {
        prefs().edit().putString("serviceError", message).commit()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        pause("系统已暂停常驻监测（后台运行时限）；系统定期检查继续，打开 App 恢复")
    }
    override fun onDestroy() {
        closed = true
        cancelSchedule()
        handler.removeCallbacksAndMessages(null)
        releaseWake()
        channel?.setMethodCallHandler(null)
        engine?.destroy(); engine = null
        instance = null
        prefs().edit().putBoolean("checking", false).commit()
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (config().optBoolean("enabled")) {
            if (prefs().getString("serviceError", "").isNullOrEmpty()) prefs().edit().putString("serviceError", "常驻服务已停止，打开 App 恢复；当前使用系统定期检查").commit()
            QuotaNotifications(this).monitorSummary(false)
        }
        super.onDestroy()
    }
}

class QuotaCheckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        // Never start a new foreground service from an idle alarm.
        QuotaMonitorService.instance?.check()
    }
}
