import 'dart:async';
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
    expect(find.text('当前桌面报告支持直接添加'), findsOneWidget);
    await tester.tap(find.text('添加桌面小组件'));
    await tester.pumpAndSettle();
    expect(pinned, true);
    expect(find.text('请求已发出，等待系统确认；尚未确认添加成功。'), findsWidgets);
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未检测到新小组件'), findsOneWidget);
    expect(find.textContaining('系统已创建桌面小组件'), findsNothing);
  });
  testWidgets('unsupported launcher tap provides feedback and manual entry', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AppStorage.channel,
          (call) async => call.method == 'widgetStatus'
              ? {'pinSupported': false, 'device': 'Custom launcher'}
              : false,
        );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WidgetSetupPanel())),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前桌面报告不支持直接添加'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('添加桌面小组件'));
    await tester.pumpAndSettle();
    expect(find.text('从系统桌面手动添加'), findsOneWidget);
    expect(find.textContaining('当前桌面未接受直接添加请求'), findsWidgets);
  });
  testWidgets(
    'actual widget IDs confirm creation rather than request acceptance',
    (tester) async {
      var count = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppStorage.channel, (call) async {
            if (call.method == 'widgetStatus') {
              return {
                'pinSupported': true,
                'widgetCount': count,
                'providerRegistered': true,
                'launcher': 'test.launcher',
              };
            }
            return true;
          });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WidgetSetupPanel())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加桌面小组件'));
      await tester.pumpAndSettle();
      count = 1;
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(find.text('系统已创建桌面小组件（共 1 个）。'), findsOneWidget);
    },
  );
  testWidgets(
    'supported launcher that never returns produces timeout feedback',
    (tester) async {
      final stalled = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppStorage.channel, (call) async {
            if (call.method == 'widgetStatus') {
              return {
                'pinSupported': true,
                'widgetCount': 0,
                'providerRegistered': true,
              };
            }
            return stalled.future;
          });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WidgetSetupPanel())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加桌面小组件'));
      await tester.pump();
      expect(find.text('正在向系统桌面请求添加…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.textContaining('系统桌面未在 8 秒内返回添加结果'), findsWidgets);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      stalled.complete(false);
      await tester.pump();
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
