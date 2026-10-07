import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cliproxy_quota/core/monitoring.dart';
import 'package:cliproxy_quota/core/updates.dart';
import 'package:cliproxy_quota/ui/update_settings.dart';

Map<String, dynamic> release(
  String version, {
  bool draft = false,
  bool prerelease = true,
  String? url,
}) => {
  'tag_name': 'v$version',
  'draft': draft,
  'prerelease': prerelease,
  'body': '改进后台检查',
  'assets': [
    {
      'name': 'cliproxy-quota-v$version.apk',
      'browser_download_url':
          url ??
          'https://github.com/wkddkw/cliproxy-quota/releases/download/v$version/cliproxy-quota-v$version.apk',
    },
  ],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'compares numeric versions and includes published preview releases',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        expect(request.headers['Authorization'], isNull);
        return http.Response(
          jsonEncode([
            release('0.1.9'),
            release('0.1.10'),
            release('0.1.11', draft: true),
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final latest = await UpdateRepository(client).check('0.1.8');
      expect(latest!.version, '0.1.10');
      expect(latest.toJson()['url'], contains('/v0.1.10/'));
      client.close();
    },
  );
  test(
    'rejects foreign asset URLs and does not offer installed or older versions',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode([
            release('0.1.7'),
            release('0.1.8'),
            release('0.1.9', url: 'https://evil.example/update.apk'),
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      expect(await UpdateRepository(client).check('0.1.8'), isNull);
      client.close();
    },
  );
  test(
    'rate limit produces a retryable message instead of declaring up to date',
    () async {
      final client = MockClient((_) async => http.Response('{}', 403));
      await expectLater(
        UpdateRepository(client).check('0.1.8'),
        throwsA(predicate((e) => '$e'.contains('稍后'))),
      );
      client.close();
    },
  );
  testWidgets('checking offers download, shows progress and can cancel', (
    tester,
  ) async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode([release('0.1.8')]),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final calls = <String>[];
    var active = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'appVersion':
              return {'version': '0.1.7', 'code': 8};
            case 'updateStatus':
              return active
                  ? {'state': 'running', 'version': '0.1.8', 'progress': 0.25}
                  : {'state': 'idle'};
            case 'startUpdate':
              active = true;
              expect((call.arguments as Map)['version'], '0.1.8');
              return 1;
            case 'cancelUpdate':
              active = false;
              return null;
          }
          return null;
        });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateSettingsPanel(repository: UpdateRepository(client)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v0.1.8'), findsOneWidget);
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('25%'), findsOneWidget);
    expect(calls, contains('startUpdate'));
    await tester.tap(find.text('取消下载'));
    await tester.pumpAndSettle();
    expect(calls, contains('cancelUpdate'));
    expect(find.text('检查更新'), findsOneWidget);
    expect(calls, isNot(contains('installUpdate')));
    await tester.pumpWidget(const SizedBox.shrink());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, null);
    client.close();
  });
  testWidgets('ready download resumes installation after granting permission', (
    tester,
  ) async {
    var allowed = false;
    var installs = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, (call) async {
          switch (call.method) {
            case 'appVersion':
              return {'version': '0.1.7', 'code': 8};
            case 'updateStatus':
              return {
                'state': 'ready',
                'version': '0.1.8',
                'canInstall': allowed,
              };
            case 'installUpdate':
              installs++;
              return allowed ? 'installer' : 'permission';
          }
          return null;
        });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UpdateSettingsPanel())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装更新'));
    await tester.pumpAndSettle();
    expect(installs, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    allowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(installs, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(installs, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, null);
  });
}
