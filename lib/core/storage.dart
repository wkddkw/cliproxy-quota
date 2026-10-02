import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'connection.dart';
import 'models.dart';

class AppStorage {
  AppStorage(this.preferences);
  final SharedPreferences preferences;
  static const secure = FlutterSecureStorage();
  static const channel = MethodChannel('com.wkddkw.cliproxy_quota/cache');
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
    await secure.write(key: 'managementKey', value: key.trim());
    await preferences.setString('connection', jsonEncode(value.toJson()));
  }

  Future<void> saveSnapshot(QuotaSnapshot value) async {
    await preferences.setString('snapshot', jsonEncode(value.toJson()));
    await channel.invokeMethod<void>(
      'writeCache',
      jsonEncode(value.toWidgetJson()),
    );
  }

  Future<void> clear() async {
    await secure.delete(key: 'managementKey');
    await preferences.remove('connection');
    await preferences.remove('snapshot');
    await channel.invokeMethod<void>('clearCache');
  }
}
