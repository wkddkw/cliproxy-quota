import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/connection.dart';
import 'package:cliproxy_quota/core/storage.dart';
import 'package:cliproxy_quota/ui/app.dart';
import 'package:cliproxy_quota/ui/usage_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'connection': jsonEncode(
        const ConnectionSettings(
          server: '',
          fullAddress: 'https://example.invalid/keeper',
          backend: 'keeper',
        ).toJson(),
      ),
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => 'test-only',
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        ),
  );
  testWidgets('usage renders estimates, model consumption and account switch', (
    tester,
  ) async {
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/auth/login')) {
        return http.Response(
          '',
          204,
          headers: {'set-cookie': 'cpa_usage_keeper_session=fixture'},
        );
      }
      if (r.url.path.endsWith('/auth/logout')) return http.Response('', 204);
      final data = r.url.path.endsWith('/overview')
          ? {
              'usage': {'total_requests': 12, 'total_tokens': 4200},
              'summary': {'total_cost': 0.3, 'cost_available': true},
            }
          : {
              'model_composition': [
                {
                  'key': 'grok-test',
                  'label': 'Grok',
                  'requests': 8,
                  'total_tokens': 3100,
                  'cost_usd': 0.2,
                  'cost_available': true,
                },
              ],
              'api_key_composition': [
                {
                  'key': 'should-not-be-shown',
                  'label': 'Team A',
                  'requests': 12,
                  'total_tokens': 4200,
                  'cost_available': false,
                },
              ],
            };
      return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
    });
    final storage = AppStorage(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: QuotaApp(storage: storage).theme(Brightness.light),
        home: UsagePage(
          storage: storage,
          client: client,
          navigation: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Grok'), findsOneWidget);
    expect(find.text('估算费用 \$0.300'), findsOneWidget);
    expect(find.textContaining('4200 Tokens'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户 / API Key').last);
    await tester.pumpAndSettle();
    expect(find.text('Team A'), findsOneWidget);
    expect(find.text('should-not-be-shown'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
