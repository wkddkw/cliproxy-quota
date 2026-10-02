import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/core/storage.dart';
import 'package:cliproxy_quota/ui/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });
  testWidgets('first launch shows settings and masked key', (tester) async {
    await tester.pumpWidget(
      QuotaApp(storage: AppStorage(await SharedPreferences.getInstance())),
    );
    await tester.pumpAndSettle();
    expect(find.text('服务器'), findsOneWidget);
    expect(find.text('管理密钥'), findsOneWidget);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .where((f) => f.obscureText)
          .length,
      1,
    );
    expect(find.text('保存并连接'), findsOneWidget);
  });
  testWidgets('unsupported provider is clear in account detail', (
    tester,
  ) async {
    final provider = ProviderQuota('Grok', [
      const AccountQuota(
        provider: 'Grok',
        name: 'grok.json',
        supported: false,
        reason: '暂不支持',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(home: AccountsPage(provider: provider)),
    );
    expect(find.text('暂不支持'), findsOneWidget);
    expect(find.text('grok.json'), findsOneWidget);
    expect(find.text('未加载'), findsNothing);
    expect(find.byIcon(Icons.delete), findsNothing);
  });
}
