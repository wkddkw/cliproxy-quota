import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/models.dart';

const account = AccountQuota(
  provider: 'Grok',
  name: 'grok.json',
  supported: false,
);
void main() {
  test('real Grok CLI weekly credit usage becomes remaining percentage', () {
    final value = account.withGrokBilling({
      'creditUsagePercent': 37,
      'currentPeriod': {
        'type': 'USAGE_PERIOD_TYPE_WEEKLY',
        'start': '2026-10-01T00:00:00Z',
        'end': '2026-10-08T00:00:00Z',
      },
    })!;
    expect(value.remaining, 63);
    expect(value.windowMinutes, 10080);
    expect(value.resetAt, DateTime.utc(2026, 10, 8));
    expect(value.supported, true);
  });
  test('monthly money wrappers use val and preserve exhausted zero', () {
    final value = account.withGrokBilling({
      'monthlyLimit': {'val': 15000},
      'used': {'val': 15000},
      'billingPeriodEnd': '2026-11-01T00:00:00Z',
    })!;
    expect(value.remaining, 0);
    expect(value.resetAt, DateTime.utc(2026, 11, 1));
  });
  test('snake-case billing fields and real period length are supported', () {
    final value = account.withGrokBilling({
      'monthly_limit': {'val': 100},
      'used': {'val': 25},
      'billing_period_start': '2026-10-01T00:00:00Z',
      'billing_period_end': '2026-11-01T00:00:00Z',
    })!;
    expect(value.remaining, 75);
    expect(value.windowMinutes, 31 * 1440);
  });
  test(
    'weekly window with missing usage does not become full or use monthly clock',
    () {
      final value = account.withGrokBilling({
        'currentPeriod': {
          'type': 'USAGE_PERIOD_TYPE_WEEKLY',
          'end': '2026-10-08T00:00:00Z',
        },
        'monthlyLimit': {'val': 100},
        'used': {'val': 5},
      })!;
      expect(value.remaining, isNull);
      expect(value.resetAt, DateTime.utc(2026, 10, 8));
      expect(value.reason, '服务未提供当前窗口的剩余百分比');
    },
  );
  test('zero monthly limit cannot produce fake full quota', () {
    expect(
      account.withGrokBilling({
        'monthlyLimit': {'val': 0},
        'used': {'val': 0},
      })!.remaining,
      isNull,
    );
  });
  for (final version in ['v8', 'v0']) {
    test(
      '$version queries auth-file Grok billing without a quota plugin',
      () async {
        final calls = <http.Request>[];
        final api = ManagementApi(
          MockClient((r) async {
            calls.add(r);
            expect(r.url.host, '100.64.0.10');
            expect(r.headers['Authorization'], 'Bearer management-key');
            if (version == 'v0' && r.url.path == '/v8/management/credentials') {
              return http.Response('', 404);
            }
            if (r.url.path.endsWith('credentials') ||
                r.url.path.endsWith('auth-files')) {
              return http.Response(
                '{"files":[{"provider":"xai","auth_index":"grok-index","name":"grok.json","sub":"user-id"}]}',
                200,
              );
            }
            if (r.url.path.endsWith('plugins')) {
              return http.Response('{"plugins":[]}', 200);
            }
            expect(
              r.url.path,
              version == 'v8'
                  ? '/v8/management/requests/api-call'
                  : '/v0/management/api-call',
            );
            expect(r.method, 'POST');
            expect(r.followRedirects, false);
            final body = jsonDecode(r.body) as Map;
            expect(body['method'], 'GET');
            expect(body['authIndex'], 'grok-index');
            expect(
              body['url'],
              isIn([
                'https://cli-chat-proxy.grok.com/v1/billing',
                'https://cli-chat-proxy.grok.com/v1/billing?format=credits',
              ]),
            );
            expect(body['header']['Authorization'], r'Bearer $TOKEN$');
            expect(body['header']['x-userid'], 'user-id');
            expect(body.containsKey('data'), false);
            return http.Response(
              jsonEncode({
                'status_code': 200,
                'body': jsonEncode({
                  'config': {'creditUsagePercent': 25},
                }),
              }),
              200,
            );
          }),
        );
        final snapshot = await api.refresh(
          const ConnectionSettings(server: '100.64.0.10'),
          'management-key',
        );
        expect(snapshot.accounts.single.remaining, 75);
        expect(snapshot.toWidgetJson()['providers'], hasLength(1));
        expect(calls.where((r) => r.method == 'POST'), hasLength(2));
      },
    );
  }
  test(
    'monthly billing is used when weekly upstream query is unavailable',
    () async {
      final api = ManagementApi(
        MockClient((r) async {
          if (r.url.path.endsWith('credentials')) {
            return http.Response(
              '{"files":[{"provider":"grok","auth_index":"1"}]}',
              200,
            );
          }
          if (r.url.path.endsWith('plugins')) {
            return http.Response('{"plugins":[]}', 200);
          }
          final url = jsonDecode(r.body)['url'] as String;
          if (url.contains('?')) {
            return http.Response('{"status_code":404,"body":""}', 200);
          }
          return http.Response(
            '{"status_code":200,"body":{"config":{"monthlyLimit":{"val":100},"used":{"val":30}}}}',
            200,
          );
        }),
      );
      final snapshot = await api.refresh(
        const ConnectionSettings(server: 'host'),
        'key',
      );
      expect(snapshot.accounts.single.remaining, 70);
    },
  );
  test(
    'failed billing query stays a query failure, never unsupported',
    () async {
      final api = ManagementApi(
        MockClient((r) async {
          if (r.url.path.endsWith('credentials')) {
            return http.Response(
              '{"files":[{"provider":"grok","auth_index":"1"}]}',
              200,
            );
          }
          if (r.url.path.endsWith('plugins')) {
            return http.Response('{"plugins":[]}', 200);
          }
          return http.Response(
            '{"status_code":401,"body":"secret should not appear"}',
            200,
          );
        }),
      );
      final snapshot = await api.refresh(
        const ConnectionSettings(server: 'host'),
        'key',
      );
      expect(snapshot.accounts.single.reason, '401 · Grok 认证失效');
      expect(snapshot.accounts.single.supported, true);
      expect(
        snapshot.toJson().toString(),
        isNot(contains('secret should not appear')),
      );
    },
  );
}
