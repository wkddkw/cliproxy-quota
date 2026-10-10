import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/core/storage.dart';
import 'package:cliproxy_quota/ui/reset_quota_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reading and canceling never reset; confirmed uncertain action submits only once',
    (tester) async {
      const settings = ConnectionSettings(
        server: 'fixture.invalid',
        port: 443,
        unified: true,
        backend: 'keeper',
      );
      SharedPreferences.setMockInitialValues({
        'connection': jsonEncode(settings.toJson()),
        'connectionEpoch': 'test',
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => 'fixture',
          );
      var mutations = 0;
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/auth/login')) {
          return http.Response(
            '',
            204,
            headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
          );
        }
        if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
        if (r.url.path.contains('/reset-credits/')) {
          return http.Response('{"availableCount":1,"credits":[]}', 200);
        }
        if (r.url.path.endsWith('/quota/reset')) {
          mutations++;
          return http.Response('{"code":"unknown"}', 200);
        }
        return http.Response('', 404);
      });
      final storage = AppStorage(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: ResetQuotaPage(
            storage: storage,
            account: const AccountQuota(
              provider: 'GPT',
              name: 'test account',
              id: 'auth',
            ),
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(mutations, 0);
      await tester.tap(find.text('使用重置权益'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(mutations, 0);
      await tester.tap(find.text('使用重置权益'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用一次并重置'));
      await tester.pumpAndSettle();
      expect(mutations, 1);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '使用重置权益'))
            .onPressed,
        isNull,
      );
    },
  );
}
