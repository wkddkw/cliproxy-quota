import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/core/monitoring.dart';
import 'package:cliproxy_quota/core/storage.dart';
import 'package:cliproxy_quota/ui/app.dart';
import 'package:cliproxy_quota/ui/notification_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('notification defaults and malformed persisted settings are safe', () {
    final defaults = MonitoringSettings.fromJson({});
    expect(defaults.threshold, 5);
    expect(defaults.enabled, false);
    expect(defaults.interval, 15);
    final malformed = MonitoringSettings.fromJson({
      'threshold': 0,
      'interval': 1,
      'mode': 'unknown',
    });
    expect(malformed.threshold, 5);
    expect(malformed.interval, 15);
    expect(malformed.mode, 'delta');
    final custom = MonitoringSettings.fromJson(
      defaults.copyWith(threshold: 10, hideDetails: true).toJson(),
    );
    expect(custom.threshold, 10);
    expect(custom.hideDetails, true);
  });
  test('notification payload hides account names and absolute amounts', () {
    final snapshot = QuotaSnapshot(DateTime.utc(2026), [
      const AccountQuota(
        provider: 'GPT',
        name: 'private@example.invalid',
        remaining: 35,
      ),
      const AccountQuota(
        provider: 'Other',
        name: 'secret.json',
        supported: false,
      ),
    ]);
    final payload = jsonEncode(Monitoring.cacheData(snapshot));
    expect(payload, isNot(contains('private@')));
    expect(payload, isNot(contains('secret.json')));
    expect(payload, isNot(contains('Other')));
    expect(payload, contains('cycle'));
  });
  testWidgets('GPT weekly detail hides zero-minute window and empty amounts', (
    tester,
  ) async {
    final account = AccountQuota.fromApi({
      'provider': 'codex',
      'name': 'example.json',
      'quota': {
        'signals': {
          'X-Codex-Primary-Used-Percent': '65',
          'X-Codex-Primary-Window-Minutes': '10080',
          'X-Codex-Secondary-Used-Percent': '0',
          'X-Codex-Secondary-Window-Minutes': '0',
        },
      },
    });
    expect(account.remaining, 35);
    expect(account.periods.length, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: AccountsPage(provider: ProviderQuota('GPT', [account])),
      ),
    );
    expect(find.textContaining('每周限额'), findsOneWidget);
    expect(find.textContaining('0 分钟'), findsNothing);
    expect(find.textContaining('Token 额度'), findsNothing);
    expect(find.textContaining('USD 额度'), findsNothing);
    expect(find.textContaining('服务未提供'), findsNothing);
  });
  testWidgets('denied notification permission leaves monitoring disabled', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'connection': jsonEncode({
        'server': 'example.invalid',
        'port': 8317,
        'fullAddress': '',
      }),
    });
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'monitoringStatus') return {'allowed': false};
          if (call.method == 'requestNotificationPermission') return false;
          return null;
        });
    final storage = AppStorage(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NotificationSettingsPanel(storage: storage),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启常驻监测'));
    await tester.pumpAndSettle();
    expect(storage.monitoringSettings.enabled, false);
    expect(calls, contains('requestNotificationPermission'));
    expect(find.textContaining('系统通知未开启'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(quotaChannel, null);
  });
  testWidgets(
    'overdue monitoring explains alarm permission and opens settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'monitoring': jsonEncode(
          const MonitoringSettings(enabled: true).toJson(),
        ),
      });
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(quotaChannel, (call) async {
            calls.add(call.method);
            if (call.method == 'monitoringStatus') {
              return {
                'enabled': true,
                'serviceRunning': true,
                'alarmMode': 'inexact',
                'exactAlarmAllowed': false,
                'nextCheck':
                    DateTime.now().millisecondsSinceEpoch - 8 * 60 * 1000,
              };
            }
            return null;
          });
      final storage = AppStorage(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NotificationSettingsPanel(storage: storage),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('计划已逾期'), findsOneWidget);
      expect(find.text('定时唤醒：系统可延迟，需允许闹钟和提醒'), findsOneWidget);
      await tester.ensureVisible(find.text('允许闹钟和提醒'));
      await tester.tap(find.text('允许闹钟和提醒'));
      await tester.pumpAndSettle();
      expect(calls, contains('openExactAlarmSettings'));
      await tester.pumpWidget(const SizedBox.shrink());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(quotaChannel, null);
    },
  );
}
