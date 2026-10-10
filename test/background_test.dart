import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/background.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/monitoring.dart';
import 'package:cliproxy_quota/core/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStorage storage;
  late List<MethodCall> calls;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'connection': jsonEncode(
        const ConnectionSettings(server: 'example.invalid').toJson(),
      ),
      'connectionEpoch': 'original',
      'monitoring': jsonEncode(
        const MonitoringSettings(enabled: true).toJson(),
      ),
    });
    storage = AppStorage(await SharedPreferences.getInstance());
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, null),
  );
  http.Response response(http.Request r) => http.Response(
    jsonEncode(
      r.url.path.endsWith('credentials')
          ? {
              'files': [
                {
                  'provider': 'codex',
                  'name': 'private@example.invalid',
                  'quota': {
                    'signals': {
                      'X-Codex-Primary-Used-Percent': '65',
                      'X-Codex-Primary-Window-Minutes': '10080',
                    },
                  },
                },
              ],
            }
          : {'plugins': []},
    ),
    200,
  );
  test(
    'worker keeps native cache sanitized and shares full snapshot locally',
    () async {
      final client = MockClient((r) async => response(r));
      await runQuotaCheck(storage, client, () async => 'fake-key');
      expect(calls.map((c) => c.method), [
        'backgroundStarted',
        'writeBackgroundCache',
      ]);
      expect(
        calls.last.arguments.toString(),
        isNot(contains('private@example.invalid')),
      );
      expect(calls.last.arguments.toString(), isNot(contains('fake-key')));
      expect(storage.snapshot, isNotNull);
      client.close();
    },
  );
  test('disabled monitor performs no request', () async {
    await storage.preferences.setString('monitoring', '{}');
    final client = MockClient(
      (_) async => throw StateError('must not request'),
    );
    await runQuotaCheck(
      storage,
      client,
      () async => throw StateError('must not read secret'),
    );
    expect(calls, isEmpty);
    client.close();
  });
  test(
    'connection change or disable during refresh discards response',
    () async {
      for (final disable in [false, true]) {
        await storage.preferences.setString('connectionEpoch', 'original');
        await storage.preferences.setString(
          'monitoring',
          jsonEncode(const MonitoringSettings(enabled: true).toJson()),
        );
        final client = MockClient((r) async {
          if (disable) {
            await storage.preferences.setString('monitoring', '{}');
          } else {
            await storage.preferences.setString('connectionEpoch', 'changed');
          }
          return response(r);
        });
        await runQuotaCheck(storage, client, () async => 'fake-key');
        expect(calls.map((c) => c.method), ['backgroundStarted']);
        calls.clear();
        client.close();
      }
    },
  );
  test(
    'failed request reports only epoch without leaking error detail',
    () async {
      final client = MockClient(
        (_) async => http.Response('private secret', 401),
      );
      await runQuotaCheck(storage, client, () async => 'fake-key');
      expect(calls.map((c) => c.method), [
        'backgroundStarted',
        'backgroundFailure',
      ]);
      expect(calls.last.arguments, 'original');
      client.close();
    },
  );
  test('transient server error requests retry; 401 does not', () async {
    for (final status in [401, 429, 503]) {
      final client = MockClient((_) async => http.Response('{}', status));
      expect(
        await runQuotaCheck(storage, client, () async => 'fake-key'),
        status == 401,
      );
      client.close();
    }
  });
  test('rejected native write cannot update foreground snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, (_) async => false);
    final client = MockClient((r) async => response(r));
    await runQuotaCheck(storage, client, () async => 'fake-key');
    expect(storage.snapshot, isNull);
    client.close();
  });
}
