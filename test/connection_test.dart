import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cliproxy_quota/core/connection.dart';

const settings = ConnectionSettings(server: '100.64.0.10');
void main() {
  test('normal settings normalize host and IPv6', () {
    expect(settings.baseUri.toString(), 'http://100.64.0.10:8317');
    expect(
      const ConnectionSettings(server: '[fd00::1]').baseUri.toString(),
      'http://[fd00::1]:8317',
    );
  });
  test('advanced address strips each supported management suffix', () {
    for (final suffix in [
      '/v8/management/',
      '/v0/management',
      '/management.html',
      '/',
    ]) {
      expect(
        ConnectionSettings(
          server: '',
          fullAddress: 'https://cpa.example.com$suffix',
        ).baseUri.toString(),
        'https://cpa.example.com',
      );
    }
  });
  test('normal settings reject ports paths and invalid ports', () {
    for (final host in [
      'example.com:8317',
      'http://example.com',
      'example.com/v1',
      '',
      'host name',
    ]) {
      expect(
        () => ConnectionSettings(server: host).baseUri,
        throwsA(isA<AppError>()),
      );
    }
    expect(
      () => const ConnectionSettings(server: 'host', port: 65536).baseUri,
      throwsA(isA<AppError>()),
    );
  });
  test('advanced address rejects user info queries and unrelated paths', () {
    for (final address in [
      'https://user:pass@host',
      'https://host?key=secret',
      'https://host/v1',
      'ftp://host',
    ]) {
      expect(
        () => ConnectionSettings(server: '', fullAddress: address).baseUri,
        throwsA(isA<AppError>()),
      );
    }
  });
  test(
    'v8 succeeds without v0; all requests are authenticated and read only',
    () async {
      final paths = <String>[];
      final api = ManagementApi(
        MockClient((request) async {
          paths.add(request.url.path);
          expect(request.method, 'GET');
          expect(request.followRedirects, false);
          expect(request.headers['Authorization'], 'Bearer test-key');
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/credentials')
                  ? {
                      'files': [
                        {'provider': 'codex', 'name': 'a'},
                      ],
                    }
                  : {'plugins': []},
            ),
            200,
          );
        }),
      );
      expect((await api.refresh(settings, 'test-key')).accounts.length, 1);
      expect(paths, ['/v8/management/credentials', '/v8/management/plugins']);
    },
  );
  test('404 alone triggers v0 auth-files fallback', () async {
    final paths = <String>[];
    final api = ManagementApi(
      MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.startsWith('/v8/')) return http.Response('', 404);
        return http.Response(
          jsonEncode(
            r.url.path.endsWith('auth-files') ? {'files': []} : {'plugins': []},
          ),
          200,
        );
      }),
    );
    await api.refresh(settings, 'test');
    expect(paths, [
      '/v8/management/credentials',
      '/v0/management/auth-files',
      '/v0/management/plugins',
    ]);
  });
  for (final status in [401, 403, 500, 302]) {
    test('$status does not cause version fallback', () async {
      var count = 0;
      final api = ManagementApi(
        MockClient((r) async {
          count++;
          return http.Response('', status);
        }),
      );
      await expectLater(
        api.refresh(settings, 'test'),
        throwsA(isA<AppError>()),
      );
      expect(count, 1);
    });
  }
  test('invalid response is distinguished from empty account list', () async {
    final api = ManagementApi(
      MockClient((r) async => http.Response('{"other":[]}', 200)),
    );
    await expectLater(api.refresh(settings, 'test'), throwsA(isA<AppError>()));
  });
  test(
    'actual enabled Grok plugin is queried via CLIProxy management host',
    () async {
      final api = ManagementApi(
        MockClient((r) async {
          expect(r.url.host, '100.64.0.10');
          expect(r.method, 'GET');
          if (r.url.path.endsWith('credentials')) {
            return http.Response(
              jsonEncode({
                'files': [
                  {
                    'provider': 'grok',
                    'auth_index': 'abc',
                    'name': 'grok.json',
                  },
                ],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('plugins')) {
            return http.Response(
              jsonEncode({
                'plugins': [
                  {
                    'id': 'grok',
                    'quota_provider': 'grok',
                    'supports_quota': true,
                    'effective_enabled': true,
                    'registered': true,
                  },
                ],
              }),
              200,
            );
          }
          expect(r.url.path, '/v8/management/plugins/grok/quota');
          expect(r.url.queryParameters['auth_index'], 'abc');
          return http.Response(
            '{"groups":[{"buckets":[{"window":"5h","remainingFraction":0.42}]}]}',
            200,
          );
        }),
      );
      final snapshot = await api.refresh(settings, 'test');
      expect(snapshot.accounts.single.remaining, 42);
      expect(snapshot.accounts.single.supported, true);
    },
  );
  test('unavailable plugin remains visible only in app', () async {
    final api = ManagementApi(
      MockClient((r) async {
        if (r.url.path.endsWith('credentials')) {
          return http.Response(
            '{"files":[{"provider":"other-provider","auth_index":"1"}]}',
            200,
          );
        }
        if (r.url.path.endsWith('plugins')) {
          return http.Response(
            '{"plugins":[{"id":"other-provider","quota_provider":"other-provider","supports_quota":true,"effective_enabled":true,"registered":true}]}',
            200,
          );
        }
        return http.Response('', 501);
      }),
    );
    final snapshot = await api.refresh(settings, 'test');
    expect(snapshot.accounts.single.reason, '暂不支持');
    expect(snapshot.toWidgetJson()['providers'], isEmpty);
  });
}
