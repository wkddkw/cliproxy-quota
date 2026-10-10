import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/keeper.dart';

void main() {
  const s = ConnectionSettings(
    server: 'fixture.invalid',
    port: 443,
    unified: true,
    backend: 'keeper',
  );
  test(
    'querying credits never consumes them; Claude request preserves explicit grant',
    () async {
      final requests = <http.Request>[];
      final c = MockClient((r) async {
        requests.add(r);
        if (r.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            204,
            headers: {
              'set-cookie':
                  'cpa_usage_keeper_session=fixture; Secure; HttpOnly',
            },
          );
        }
        if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
        return http.Response(
          '{"availableCount":2,"credits":[],"code":"reset"}',
          200,
        );
      });
      final api = KeeperApi(c);
      await api.resetOptions(s, 'fixture', 'auth-index', claude: false);
      expect(requests.any((r) => r.url.path.endsWith('/quota/reset')), false);
      expect(
        requests.any(
          (r) =>
              r.method == 'GET' &&
              r.url.path.endsWith('/reset-credits/auth-index'),
        ),
        true,
      );
      requests.clear();
      await api.resetQuota(
        s,
        'fixture',
        'auth-index',
        grantId: 'grant',
        organizationId: 'org',
      );
      final mutation = requests.singleWhere(
        (r) => r.url.path.endsWith('/quota/reset'),
      );
      expect(mutation.method, 'POST');
      expect(jsonDecode(mutation.body), {
        'auth_index': 'auth-index',
        'grant_id': 'grant',
        'organization_id': 'org',
      });
      expect(mutation.headers['X-CPA-Usage-Keeper-Request'], 'fetch');
      c.close();
    },
  );
  test('uncertain mutation response is not retried', () async {
    int attempts = 0;
    final c = MockClient((r) async {
      if (r.url.path.endsWith('/auth/login')) {
        return http.Response(
          '',
          204,
          headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
        );
      }
      if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
      attempts++;
      throw http.ClientException('disconnected');
    });
    final result = await KeeperApi(c).resetQuota(s, 'fixture', 'auth-index');
    expect(result['code'], 'unknown');
    expect(attempts, 1);
    c.close();
  });
}
