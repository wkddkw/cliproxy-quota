import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cliproxy_quota/core/storage.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/ui/app.dart';
import 'package:cliproxy_quota/ui/widget_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('supported launcher can request the system pin confirmation', (
    tester,
  ) async {
    var pinned = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppStorage.channel, (call) async {
          if (call.method == 'widgetStatus') {
            return {'pinSupported': true, 'device': 'OnePlus 13T'};
          }
          if (call.method == 'pinWidget') {
            pinned = true;
            return true;
          }
          return null;
        });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WidgetSetupPanel())),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前桌面支持直接添加'), findsOneWidget);
    await tester.tap(find.text('添加桌面小组件'));
    await tester.pumpAndSettle();
    expect(pinned, true);
    expect(find.text('已请求系统确认，请在桌面弹窗中点击添加。'), findsOneWidget);
  });
  testWidgets(
    'unsupported launcher explains manual entry and disables pin request',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            AppStorage.channel,
            (_) async => {'pinSupported': false, 'device': 'Custom launcher'},
          );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WidgetSetupPanel())),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前桌面不支持直接添加，可尝试手动添加'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'GPT Claude and Grok cards use image marks instead of text initials',
    (tester) async {
      for (final name in ['GPT', 'Claude', 'Grok']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProviderCard(
                provider: ProviderQuota(name, [
                  AccountQuota(provider: name, name: 'fixture', remaining: 50),
                ]),
                onTap: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        final image =
            tester.widget<Image>(find.byType(Image)).image as AssetImage;
        expect(image.assetName, 'assets/providers/${name.toLowerCase()}.png');
      }
    },
  );
}
