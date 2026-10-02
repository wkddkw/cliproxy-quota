import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/live_quota.dart';
import 'package:cliproxy_quota/core/models.dart';

const settings = ConnectionSettings(server: 'example.invalid');
const passiveFile = {
  'provider': 'codex',
  'name': 'example.json',
  'auth_index': 'fixture-index',
  'id_token': {'chatgpt_account_id': 'fixture-account'},
  'quota': {
    'observed_at': '2026-10-03T01:42:00Z',
    'signals': {
      'X-Codex-Primary-Used-Percent': '65',
      'X-Codex-Primary-Window-Minutes': '10080',
    },
  },
};
const freshPayload = {
  'rate_limit': {
    'primary_window': {
      'used_percent': 80,
      'limit_window_seconds': 604800,
      'reset_at': 1791115200,
    },
    'secondary_window': {'used_percent': 0, 'limit_window_seconds': 0},
  },
};
void main() {
  test(
    'refresh actively reads GPT via management proxy and replaces old quota',
    () async {
      final requests = <http.Request>[];
      final before = DateTime.now().toUtc();
      final client = MockClient((r) async {
        requests.add(r);
        expect(r.url.host, 'example.invalid');
        expect(r.headers['Authorization'], 'Bearer fake-management-key');
        if (r.url.path.endsWith('credentials')) {
          return http.Response(
            jsonEncode({
              'files': [passiveFile],
            }),
            200,
          );
        }
        if (r.url.path.endsWith('plugins')) {
          return http.Response('{"plugins":[]}', 200);
        }
        expect(r.url.path, '/v8/management/requests/api-call');
        expect(r.method, 'POST');
        final body = jsonDecode(r.body) as Map;
        expect(body['method'], 'GET');
        expect(body['url'], 'https://chatgpt.com/backend-api/wham/usage');
        expect(body['authIndex'], 'fixture-index');
        expect(body['header']['Authorization'], r'Bearer $TOKEN$');
        expect(body['header']['Chatgpt-Account-Id'], 'fixture-account');
        return http.Response(
          jsonEncode({'status_code': 200, 'body': jsonEncode(freshPayload)}),
          200,
        );
      });
      final account = (await ManagementApi(
        client,
      ).refresh(settings, 'fake-management-key')).accounts.single;
      expect(requests.length, 3);
      expect(account.remaining, 20);
      expect(account.queried, true);
      expect(account.observedAt!.isBefore(before), false);
      expect(account.periods.single.label, '每周限额');
      expect(account.reason, isNull);
      client.close();
    },
  );
  test(
    'v0 active-query route and camel-case auth index are supported',
    () async {
      final client = MockClient((r) async {
        if (r.url.path.endsWith('credentials')) return http.Response('', 404);
        if (r.url.path.endsWith('auth-files')) {
          return http.Response(
            jsonEncode({
              'files': [
                {
                  ...passiveFile,
                  'auth_index': null,
                  'authIndex': 'camel-index',
                },
              ],
            }),
            200,
          );
        }
        if (r.url.path.endsWith('plugins')) {
          return http.Response('{"plugins":[]}', 200);
        }
        expect(r.url.path, '/v0/management/api-call');
        expect(jsonDecode(r.body)['authIndex'], 'camel-index');
        return http.Response(
          jsonEncode({'status_code': 200, 'body': freshPayload}),
          200,
        );
      });
      expect(
        (await ManagementApi(
          client,
        ).refresh(settings, 'fake-key')).accounts.single.remaining,
        20,
      );
      client.close();
    },
  );
  test(
    'query errors retain original timestamp and mark old quota, preventing alerts',
    () async {
      for (final failure in [401, 403, 429, 500]) {
        final client = MockClient((r) async {
          if (r.url.path.endsWith('credentials')) {
            return http.Response(
              jsonEncode({
                'files': [passiveFile],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('plugins')) {
            return http.Response('{"plugins":[]}', 200);
          }
          return http.Response(
            jsonEncode({
              'status_code': failure,
              'body': 'Bearer private-error-secret',
            }),
            200,
          );
        });
        final snapshot = await ManagementApi(
          client,
        ).refresh(settings, 'fake-key');
        final account = snapshot.accounts.single;
        expect(account.remaining, 35);
        expect(account.observedAt, DateTime.utc(2026, 10, 3, 1, 42));
        expect(account.queried, false);
        expect(account.reason, contains('显示旧数据'));
        expect(snapshot.providers.single.remaining, isNull);
        expect(
          account.toJson().toString(),
          isNot(contains('private-error-secret')),
        );
        client.close();
      }
    },
  );
  test(
    'Claude active usage is percentage, not fraction, and prefers five hours',
    () async {
      final client = MockClient((r) async {
        if (r.url.path.endsWith('credentials')) {
          return http.Response(
            '{"files":[{"provider":"claude","auth_index":"1"}]}',
            200,
          );
        }
        if (r.url.path.endsWith('plugins')) {
          return http.Response('{"plugins":[]}', 200);
        }
        final body = jsonDecode(r.body);
        expect(body['url'], 'https://api.anthropic.com/api/oauth/usage');
        expect(body['header']['anthropic-beta'], 'oauth-2025-04-20');
        return http.Response(
          jsonEncode({
            'status_code': 200,
            'body': {
              'five_hour': {
                'utilization': 40,
                'resets_at': '2026-10-03T12:00:00Z',
              },
              'seven_day': {
                'utilization': 80,
                'resets_at': '2026-10-08T12:00:00Z',
              },
            },
          }),
          200,
        );
      });
      final account = (await ManagementApi(
        client,
      ).refresh(settings, 'fake-key')).accounts.single;
      expect(account.remaining, 60);
      expect(account.windowMinutes, 300);
      expect(account.periods.length, 2);
      client.close();
    },
  );
  test(
    'invalid live payload cannot fabricate quota or retain old data as fresh',
    () {
      final account = AccountQuota.fromApi(passiveFile);
      final now = DateTime.utc(2026, 10, 3, 7);
      for (final used in [null, 'NaN', -1, 101]) {
        expect(
          liveQuota(account, {
            'rate_limit': {
              'primary_window': {
                'used_percent': used,
                'limit_window_seconds': 18000,
              },
            },
          }, now),
          isNull,
        );
      }
      final valid = liveQuota(account, {
        'rateLimit': {
          'primaryWindow': {
            'usedPercent': 100,
            'limitWindowSeconds': 18000,
            'resetAfterSeconds': 60,
          },
        },
      }, now)!;
      expect(valid.remaining, 0);
      expect(valid.resetAt, now.add(const Duration(minutes: 1)));
      expect(AccountQuota.fromJson(valid.toJson()).queried, true);
    },
  );
  test(
    'disabled accounts and API-key OpenAI do not issue OAuth queries',
    () async {
      final client = MockClient((r) async {
        expect(r.method, 'GET');
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('credentials')
                ? {
                    'files': [
                      {...passiveFile, 'disabled': true},
                      {'provider': 'openai', 'auth_index': '2'},
                    ],
                  }
                : {'plugins': []},
          ),
          200,
        );
      });
      final snapshot = await ManagementApi(
        client,
      ).refresh(settings, 'fake-key');
      expect(snapshot.accounts.first.reason, '已禁用');
      expect(snapshot.accounts.last.supported, false);
      client.close();
    },
  );
}
