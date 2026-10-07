import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/background.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/core/monitoring.dart';
import 'package:cliproxy_quota/core/storage.dart';

Future<Map<String, dynamic>> status() async =>
    await quotaChannel.invokeMapMethod<String, dynamic>('monitoringStatus') ??
    {};

Future<Map<String, dynamic>> waitFor(
  bool Function(Map<String, dynamic>) predicate,
) async {
  for (var i = 0; i < 120; i++) {
    final value = await status();
    if (predicate(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError('Monitoring state did not converge: ${await status()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'scheduled worker queries and alerts without an ongoing notification',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Quota worker smoke test')),
        ),
      );
      await tester.runAsync(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
        final storage = AppStorage(prefs);
        var queries = 0;
        final reset = DateTime.now().toUtc().add(const Duration(days: 7));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          Object payload;
          if (request.uri.path.endsWith('/credentials')) {
            payload = {
              'files': [
                {
                  'provider': 'codex',
                  'name': 'example.json',
                  'auth_index': 'fixture',
                },
              ],
            };
          } else if (request.uri.path.endsWith('/plugins')) {
            payload = {'plugins': []};
          } else if (request.uri.path.endsWith('/api-call')) {
            final body = jsonDecode(await utf8.decoder.bind(request).join());
            expect(body['url'], 'https://chatgpt.com/backend-api/wham/usage');
            expect(body['method'], 'GET');
            queries++;
            payload = {
              'status_code': 200,
              'body': {
                'rate_limit': {
                  'primary_window': {
                    'used_percent': queries == 1 ? 20 : 26,
                    'limit_window_seconds': 604800,
                    'reset_at': reset.millisecondsSinceEpoch ~/ 1000,
                  },
                },
              },
            };
          } else {
            request.response.statusCode = 404;
            payload = {};
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(payload));
          await request.response.close();
        });
        try {
          // CI grants POST_NOTIFICATIONS once Flutter installs the debug app.
          await waitFor((s) => s['allowed'] == true);
          await initializeAndroidMonitoring(storage);
          expect(Monitoring.startupError, isNull);
          await storage.saveConnection(
            ConnectionSettings(server: '127.0.0.1', port: server.port),
            'fake-key',
          );
          await storage.saveMonitoring(const MonitoringSettings(enabled: true));
          final first = await waitFor(
            (s) =>
                (s['lastBackgroundCheck'] as num? ?? 0) > 0 &&
                s['checking'] == false,
          );
          expect(queries, 1);
          expect(first['overviewVisible'], false);
          expect(first['overviewOngoing'], false);
          expect(first['lastBackgroundError'], '');
          expect(first['alertsVisible'], 0);
          final scheduled = await waitFor(
            (s) => (s['scheduledJobIds'] as List).isNotEmpty,
          );
          // Force the actual WorkManager job and verify its independent engine.
          debugPrint(
            'QUOTA_SMOKE_RUN_JOB:${(scheduled['scheduledJobIds'] as List).first}',
          );
          final second = await waitFor(
            (s) =>
                (s['lastBackgroundCheck'] as num? ?? 0) >
                    (first['lastBackgroundCheck'] as num) &&
                (s['alertsVisible'] as num? ?? 0) > 0 &&
                s['checking'] == false,
          );
          expect(queries, 2);
          expect(second['overviewVisible'], false);
          expect(second['overviewOngoing'], false);
          final backgroundTime = second['lastBackgroundCheck'];
          await storage.saveSnapshot(
            QuotaSnapshot(DateTime.now().toUtc(), [
              AccountQuota(
                provider: 'GPT',
                name: 'example.json',
                remaining: 74,
                resetAt: reset,
                windowMinutes: 10080,
              ),
            ]),
          );
          expect(
            (await status())['lastBackgroundCheck'],
            backgroundTime,
            reason:
                'Foreground refresh must not pretend to be a background check',
          );
          await storage.saveMonitoring(const MonitoringSettings());
          await waitFor(
            (s) =>
                s['enabled'] == false &&
                (s['scheduledJobIds'] as List).isEmpty &&
                s['overviewVisible'] == false,
          );
          await prefs.reload();
          expect(storage.monitoringSettings.enabled, false);
          expect(storage.settings, isNotNull);
          expect(await storage.readKey(), 'fake-key');
        } finally {
          await storage.clear();
          await server.close(force: true);
        }
      });
    },
  );
}
