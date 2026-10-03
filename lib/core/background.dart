import 'dart:convert';
import 'dart:async';
import 'dart:ui' show PluginUtilities;
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'connection.dart';
import 'monitoring.dart';
import 'storage.dart';

@pragma('vm:entry-point')
void quotaBackgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task != 'quota-monitor') return true;
    // A running foreground engine owns the interval; the worker is fallback.
    if (await quotaChannel.invokeMethod<bool>('serviceRunning') == true) {
      return true;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final storage = AppStorage(prefs);
    final client = http.Client();
    try {
      return await runQuotaCheck(storage, client, storage.readKey);
    } finally {
      client.close();
    }
  });
}

// Shared worker logic can be exercised without starting an Android engine.
Future<bool> runQuotaCheck(
  AppStorage storage,
  http.Client client,
  Future<String> Function() readKey, {
  bool service = false,
}) async {
  final settings = storage.settings;
  final epoch = storage.connectionEpoch;
  if (!storage.monitoringSettings.enabled ||
      settings == null ||
      epoch.isEmpty) {
    return true;
  }
  try {
    await quotaChannel.invokeMethod<void>('backgroundStarted', {
      'epoch': epoch,
    });
    final snapshot = await ManagementApi(
      client,
    ).refresh(settings, await readKey());
    await storage.preferences.reload();
    if (!storage.monitoringSettings.enabled ||
        storage.connectionEpoch != epoch) {
      return true;
    }
    // The native epoch guard also rejects a response that finishes after the
    // user changes/clears a connection or switches off monitoring.
    await quotaChannel.invokeMethod<bool>(
      service ? 'writeServiceCache' : 'writeBackgroundCache',
      {'epoch': epoch, 'snapshot': jsonEncode(Monitoring.cacheData(snapshot))},
    );
  } catch (_) {
    try {
      await quotaChannel.invokeMethod<void>('backgroundFailure', epoch);
    } catch (_) {}
  }
  return true;
}

const serviceChannel = MethodChannel('com.wkddkw.cliproxy_quota/service');

@pragma('vm:entry-point')
void quotaServiceDispatcher() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final storage = AppStorage(prefs);
  final client = http.Client();
  bool checking = false;
  serviceChannel.setMethodCallHandler((call) async {
    if (call.method != 'check' || checking) return;
    checking = true;
    try {
      await prefs.reload();
      await runQuotaCheck(storage, client, storage.readKey, service: true);
    } finally {
      checking = false;
      await serviceChannel.invokeMethod<void>('complete');
    }
  });
  await serviceChannel.invokeMethod<void>('ready');
}

class MonitoringLifecycle with WidgetsBindingObserver {
  MonitoringLifecycle(this.storage);
  final AppStorage storage;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(resume());
  }

  Future<void> resume() async {
    try {
      await storage.preferences.reload();
      if (storage.monitoringSettings.enabled) {
        await Monitoring.configureNative(storage.monitoringSettings);
      }
    } catch (_) {}
  }
}

Future<void> initializeAndroidMonitoring(AppStorage storage) async {
  if (!Platform.isAndroid) return;
  try {
    Monitoring.serviceCallback = PluginUtilities.getCallbackHandle(
      quotaServiceDispatcher,
    )?.toRawHandle();
    if (Monitoring.serviceCallback == null) throw const AppError('无法注册后台查询入口');
    await storage.ensureConnectionEpoch();
    await Workmanager().initialize(quotaBackgroundDispatcher);
    await Monitoring.configure(storage.monitoringSettings);
    WidgetsBinding.instance.addObserver(MonitoringLifecycle(storage));
  } catch (_) {
    Monitoring.startupError = '后台检查初始化失败，请重启 App 后再试';
  }
}
