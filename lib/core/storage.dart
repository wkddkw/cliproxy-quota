import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'monitoring.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'connection.dart';
import 'models.dart';

class AppStorage {
  AppStorage(this.preferences);
  final SharedPreferences preferences;
  static const secure = FlutterSecureStorage();
  static const channel = quotaChannel;
  String get connectionEpoch => preferences.getString('connectionEpoch') ?? '';
  String newEpoch() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  MonitoringSettings get monitoringSettings {
    try {
      return MonitoringSettings.fromJson(
        Json.from(jsonDecode(preferences.getString('monitoring') ?? '{}')),
      );
    } catch (_) {
      return const MonitoringSettings();
    }
  }

  Future<void> saveMonitoring(MonitoringSettings value) async {
    try {
      await Monitoring.configure(value);
    } catch (_) {
      await preferences.setString(
        'monitoring',
        jsonEncode(value.copyWith(enabled: false).toJson()),
      );
      rethrow;
    }
    await preferences.setString('monitoring', jsonEncode(value.toJson()));
  }

  Future<void> ensureConnectionEpoch() async {
    if (connectionEpoch.isEmpty) {
      await preferences.setString('connectionEpoch', newEpoch());
    }
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('setConnectionEpoch', connectionEpoch);
    }
  }

  ConnectionSettings? get settings {
    try {
      final value = preferences.getString('connection');
      return value == null
          ? null
          : ConnectionSettings.fromJson(Json.from(jsonDecode(value)));
    } catch (_) {
      return null;
    }
  }

  QuotaSnapshot? get snapshot {
    try {
      final value = preferences.getString('snapshot');
      return value == null
          ? null
          : QuotaSnapshot.fromJson(Json.from(jsonDecode(value)));
    } catch (_) {
      return null;
    }
  }

  Future<String> readKey() async =>
      await secure.read(key: 'managementKey') ?? '';
  Future<void> saveConnection(ConnectionSettings value, String key) async {
    final epoch = newEpoch();
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('setConnectionEpoch', epoch);
    }
    await preferences.setString('connectionEpoch', epoch);
    await secure.write(key: 'managementKey', value: key.trim());
    await preferences.setString('connection', jsonEncode(value.toJson()));
  }

  Future<void> saveSnapshot(QuotaSnapshot value) async {
    if (Platform.isAndroid) {
      final accepted = await channel.invokeMethod<bool>('writeCache', {
        'epoch': connectionEpoch,
        'snapshot': jsonEncode(Monitoring.cacheData(value)),
      });
      if (accepted == false) return;
    } else {
      await channel.invokeMethod<void>(
        'writeCache',
        jsonEncode(value.toWidgetJson()),
      );
    }
    await preferences.setString('snapshot', jsonEncode(value.toJson()));
  }

  Future<void> clear() async {
    // Invalidate in-flight background responses before removing secrets.
    final epoch = newEpoch();
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('setConnectionEpoch', epoch);
    }
    await preferences.setString('connectionEpoch', epoch);
    await saveMonitoring(const MonitoringSettings());
    await secure.delete(key: 'managementKey');
    await preferences.remove('connection');
    await preferences.remove('snapshot');
    await channel.invokeMethod<void>('clearCache');
  }
}
