import 'dart:convert';
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
  Future<String> Function() readKey,
) async {
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
    await quotaChannel.invokeMethod<bool>('writeBackgroundCache', {
      'epoch': epoch,
      'snapshot': jsonEncode(Monitoring.cacheData(snapshot)),
    });
  } catch (_) {
    try {
      await quotaChannel.invokeMethod<void>('backgroundFailure', epoch);
    } catch (_) {}
  }
  return true;
}

Future<void> initializeAndroidMonitoring(AppStorage storage) async {
  if (!Platform.isAndroid) return;
  try {
    await storage.ensureConnectionEpoch();
    await Workmanager().initialize(quotaBackgroundDispatcher);
    await Monitoring.configure(storage.monitoringSettings);
  } catch (_) {
    Monitoring.startupError = '后台检查初始化失败，请重启 App 后再试';
  }
}
