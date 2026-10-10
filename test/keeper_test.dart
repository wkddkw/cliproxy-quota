import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/keeper.dart';

void main() {
  const settings = ConnectionSettings(
    server: '',
    fullAddress: 'https://example.invalid/keeper/',
    backend: 'keeper',
  );
  final identity = {
    'id': '42',
    'identity': 'auth-index',
    'provider': 'xai',
    'displayName': 'Grok A',
  };
  final completed = {
    'status': 'completed',
    'refreshed_at': '2026-10-10T00:00:00Z',
    'quota': {
      'quota': [
        {
          'key': 'billing.weekly',
          'label': '每周限额',
          'metric': 'percent',
          'usedPercent': 20,
          'window': {'seconds': 604800},
          'resetAt': '2026-10-17T00:00:00Z',
        },
        {
          'key': 'billing.monthly',
          'label': '月度金额',
          'metric': 'usd_cents',
          'limit': 2000,
          'used': 500,
          'remaining': 1500,
        },
      ],
    },
  };
  test('Keeper preserves base path, CPA still rejects arbitrary paths', () {
    expect(settings.baseUri.path, '/keeper');
    expect(ConnectionSettings.fromJson(settings.toJson()).isKeeper, isTrue);
    expect(
      () => const ConnectionSettings(
        server: '',
        fullAddress: 'https://example.invalid/keeper',
      ).baseUri,
      throwsA(isA<AppError>()),
    );
  });
  test('normalized weekly and monetary windows stay separate', () {
    final a = parseKeeperAccount(identity, completed);
    expect(a.provider, 'Grok');
    expect(a.remaining, 80);
    expect(a.periods[0].usd.hasData, isFalse);
    expect(a.periods[1].usd.total, 20);
    expect(a.periods[1].usd.remaining, 15);
    expect(a.observedAt, DateTime.utc(2026, 10, 10));
  });
  test('unknown weekly percent does not borrow monthly percentage', () {
    final a = parseKeeperAccount(identity, {
      'status': 'completed',
      'quota': {
        'quota': [
          {'key': 'billing.weekly', 'label': '每周限额'},
          {
            'key': 'billing.monthly',
            'metric': 'usd_cents',
            'limit': 2000,
            'used': 500,
          },
        ],
      },
    });
    expect(a.remaining, isNull);
    expect(a.periods[1].usd.remaining, 15);
  });
  test(
    'cookie auth, path prefix, auth index and queue polling match Keeper',
    () async {
      final paths = <String>[];
      final client = MockClient((r) async {
        paths.add(r.url.path);
        expect(r.url.host, 'example.invalid');
        expect(r.followRedirects, isFalse);
        if (r.method == 'POST') {
          expect(r.headers['X-CPA-Usage-Keeper-Request'], 'fetch');
        }
        if (r.url.path.endsWith('/auth/login')) {
          expect(jsonDecode(r.body), {'password': 'test-only-password'});
          expect(r.headers['Authorization'], isNull);
          return http.Response(
            '',
            204,
            headers: {
              'set-cookie':
                  'cpa_usage_keeper_session=fixture; Path=/keeper; HttpOnly; Secure',
            },
          );
        }
        expect(r.headers['Cookie'], 'cpa_usage_keeper_session=fixture');
        if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
        if (r.url.path.endsWith('/identities/page')) {
          return http.Response(
            jsonEncode({
              'identities': [identity],
              'total_pages': 1,
            }),
            200,
          );
        }
        if (r.url.path.endsWith('/quota/cache')) {
          return http.Response('{"items":[]}', 200);
        }
        if (r.url.path.endsWith('/quota/refresh')) {
          expect(jsonDecode(r.body)['auth_indexes'], ['auth-index']);
          return http.Response('{"tasks":[{"authIndex":"auth-index"}]}', 200);
        }
        if (r.url.path.endsWith('/quota/refresh/auth-index')) {
          return http.Response.bytes(utf8.encode(jsonEncode(completed)), 200);
        }
        throw StateError('Unexpected request ${r.url}');
      });
      final result = await ManagementApi(
        client,
      ).refresh(settings, 'test-only-password');
      expect(result.accounts.single.remaining, 80);
      expect(result.accounts.single.resetAt, DateTime.utc(2026, 10, 17));
      expect(paths, contains('/keeper/api/v1/quota/refresh'));
      expect(paths, contains('/keeper/api/v1/quota/refresh/auth-index'));
      expect(paths.every((p) => p.startsWith('/keeper/api/v1/')), isTrue);
      expect(paths.last, endsWith('/auth/logout'));
      client.close();
    },
  );
  test(
    'login redirects are rejected and password never sent to destination',
    () async {
      var count = 0;
      final client = MockClient((r) async {
        count++;
        return http.Response(
          '',
          302,
          headers: {'location': 'https://elsewhere.invalid'},
        );
      });
      await expectLater(
        KeeperApi(client).refresh(settings, 'fixture'),
        throwsA(isA<AppError>()),
      );
      expect(count, 1);
      client.close();
    },
  );
  test(
    'usage requests specify validated range and never quota refresh',
    () async {
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            204,
            headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
          );
        }
        if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
        expect(r.method, 'GET');
        expect(r.url.queryParameters['range'], '7d');
        expect(r.url.path, isNot(contains('/quota')));
        return http.Response('{}', 200);
      });
      await KeeperApi(client).usage(settings, 'fixture', 7);
      client.close();
    },
  );
  test('failed refresh retains cached numbers but marks them as old', () {
    final a = parseKeeperAccount(identity, completed, failure: '本次查询失败');
    expect(a.remaining, 80);
    expect(a.reason, '本次查询失败');
    expect(a.observedAt, DateTime.utc(2026, 10, 10));
  });
  test('one transient polling failure does not hide another account', () async {
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/auth/login')) {
        return http.Response(
          '',
          204,
          headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
        );
      }
      if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
      if (r.url.path.endsWith('/identities/page')) {
        return http.Response(
          jsonEncode({
            'identities': [
              identity,
              {...identity, 'id': '43', 'identity': 'bad-index'},
            ],
            'total_pages': 1,
          }),
          200,
        );
      }
      if (r.url.path.endsWith('/quota/cache')) {
        return http.Response('{"items":[]}', 200);
      }
      if (r.url.path.endsWith('/quota/refresh')) {
        return http.Response(
          '{"tasks":[{"authIndex":"auth-index"},{"authIndex":"bad-index"}]}',
          200,
        );
      }
      if (r.url.path.endsWith('bad-index')) return http.Response('{}', 503);
      return http.Response.bytes(utf8.encode(jsonEncode(completed)), 200);
    });
    final result = await KeeperApi(client).refresh(settings, 'fixture');
    expect(result.accounts[0].remaining, 80);
    expect(result.accounts[1].remaining, isNull);
    expect(result.providers.single.availableCount, 1);
    client.close();
  });
  test(
    'auth indexes with reserved path characters remain one segment',
    () async {
      final id = 'account/a b';
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            204,
            headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
          );
        }
        if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
        if (r.url.path.endsWith('/identities/page')) {
          return http.Response(
            jsonEncode({
              'identities': [
                {...identity, 'identity': id},
              ],
              'total_pages': 1,
            }),
            200,
          );
        }
        if (r.url.path.endsWith('/quota/cache')) {
          return http.Response('{"items":[]}', 200);
        }
        if (r.url.path.endsWith('/quota/refresh')) {
          return http.Response(
            jsonEncode({
              'tasks': [
                {'authIndex': id},
              ],
            }),
            200,
          );
        }
        expect(r.url.pathSegments.last, id);
        return http.Response.bytes(utf8.encode(jsonEncode(completed)), 200);
      });
      await KeeperApi(client).refresh(settings, 'fixture');
      client.close();
    },
  );
  test(
    'selected calendar day filters overview and every user together',
    () async {
      var reads = 0;
      final c = MockClient((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            204,
            headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
          );
        }
        if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
        expect(r.url.queryParameters, {
          'range': 'custom',
          'unit': 'day',
          'start': '2026-10-09',
          'end': '2026-10-09',
        });
        reads++;
        return http.Response('{}', 200);
      });
      await KeeperApi(c).usage(settings, 'fixture', 7, day: '2026-10-09');
      expect(reads, 2);
      c.close();
    },
  );
}
