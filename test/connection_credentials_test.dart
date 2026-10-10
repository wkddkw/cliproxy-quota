import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'legacy active secret and separate backend credentials survive switching',
    () async {
      const old = ConnectionSettings(server: 'old', backend: 'cpa');
      SharedPreferences.setMockInitialValues({
        'connection': jsonEncode(old.toJson()),
      });
      final secrets = <String, String>{'managementKey': 'cpa-old'};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              if (call.method == 'read') return secrets[args['key']];
              if (call.method == 'write') secrets[args['key']] = args['value'];
              return null;
            },
          );
      final storage = AppStorage(await SharedPreferences.getInstance());
      expect(await storage.readBackendKey('cpa'), 'cpa-old');
      expect(await storage.readBackendKey('keeper'), '');
      const keeper = ConnectionSettings(
        server: 'host',
        unified: true,
        backend: 'keeper',
      );
      await storage.saveConnection(
        keeper,
        ' keeper ',
        cpaKey: 'cpa-old',
        keeperKey: ' keeper ',
      );
      expect(await storage.readKey(), ' keeper ');
      expect(await storage.readBackendKey('cpa'), 'cpa-old');
      const cpa = ConnectionSettings(
        server: 'host',
        unified: true,
        backend: 'cpa',
      );
      await storage.saveConnection(
        cpa,
        'cpa-old',
        cpaKey: 'cpa-old',
        keeperKey: ' keeper ',
      );
      expect(await storage.readKey(), 'cpa-old');
      expect(await storage.readBackendKey('keeper'), ' keeper ');
    },
  );
}
