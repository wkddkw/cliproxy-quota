import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/core/quota_details.dart';
import 'package:cliproxy_quota/ui/quota_period_view.dart';

void main() {
  test(
    'weekly percentage keeps its cycle while monthly response supplies USD',
    () {
      const account = AccountQuota(provider: 'Grok', name: 'fixture');
      final weekly = account.withGrokBilling({
        'creditUsagePercent': 37,
        'monthlyLimit': {'val': 0},
        'used': {'val': 0},
        'billingPeriodEnd': '2026-11-01T00:00:00Z',
      })!;
      final monthly = account.withGrokBilling({
        'monthlyLimit': {'val': 15000},
        'used': {'val': 1500},
        'billingPeriodEnd': '2026-11-01T00:00:00Z',
      })!;
      final merged = weekly.withBillingDetails(monthly);
      expect(merged.remaining, 63);
      expect(merged.resetAt, isNull);
      expect(merged.periods.first.usd.hasData, false);
      expect(merged.periods.last.usd.remaining, 135);
      expect(merged.periods.last.end, DateTime.utc(2026, 11, 1));
    },
  );
  test('remaining token amount derives only from explicit total and used', () {
    final value = QuotaAmounts.values(total: 1000000, used: 250000);
    expect(value.remaining, 750000);
    expect(QuotaAmounts.values(used: 100).remaining, isNull);
    expect(QuotaAmounts.values(total: 100, used: 120).remaining, 0);
  });
  test('Grok cents become USD without borrowing weekly dates', () {
    final periods = QuotaPeriod.fromGrok({
      'creditUsagePercent': 37,
      'currentPeriod': {
        'type': 'USAGE_PERIOD_TYPE_WEEKLY',
        'end': '2026-10-08T00:00:00Z',
      },
      'monthlyLimit': {'val': 15000},
      'used': {'val': 1500},
      'billingPeriodEnd': '2026-11-01T00:00:00Z',
    });
    expect(periods.first.end, DateTime.utc(2026, 10, 8));
    expect(periods.first.usd.hasData, false);
    expect(periods.last.end, DateTime.utc(2026, 11, 1));
    expect(periods.last.usd.total, 150);
    expect(periods.last.usd.used, 15);
    expect(periods.last.usd.remaining, 135);
    expect(periods.last.tokens.hasData, false);
  });
  test('plugin amounts preserve explicit token and USD units in a bucket', () {
    final periods = QuotaPeriod.fromPlugin({
      'groups': [
        {
          'displayName': 'Primary',
          'buckets': [
            {
              'window': '5h',
              'remainingFraction': 0.5,
              'tokens': {'total': 10000, 'remaining': 5000},
              'usd': {'total': 20, 'used': 10},
            },
          ],
        },
      ],
    });
    expect(periods.single.tokens.used, 5000);
    expect(periods.single.usd.remaining, 10);
  });
  test('USD token cost is not misread as a token count', () {
    final period = QuotaPeriod.fromPlugin({
      'summary': [
        {
          'key': 'token_cost_used',
          'currency': 'USD',
          'format': 'currency',
          'value': 5,
        },
        {'key': 'tokens_total', 'unit': 'tokens', 'value': 1000},
        {'key': 'tokens_used', 'unit': 'tokens', 'value': 400},
      ],
    }).single;
    expect(period.tokens.used, 400);
    expect(period.tokens.remaining, 600);
    expect(period.usd.used, 5);
  });
  test('percentage-only bucket does not invent token or money budget', () {
    final period = QuotaPeriod.fromPlugin({
      'groups': [
        {
          'buckets': [
            {'window': '5h', 'remainingFraction': 0.5},
          ],
        },
      ],
    }).single;
    expect(period.tokens.hasData, false);
    expect(period.usd.hasData, false);
  });
  test('cache keeps app amount details while widget stays percentage-only', () {
    final snapshot = QuotaSnapshot(DateTime.utc(2026, 10, 2), [
      AccountQuota(
        provider: 'Grok',
        name: 'fixture',
        remaining: 50,
        periods: [
          QuotaPeriod(
            label: 'Monthly',
            usd: QuotaAmounts.values(total: 150, used: 15),
          ),
        ],
      ),
    ]);
    expect(
      QuotaSnapshot.fromJson(
        snapshot.toJson(),
      ).accounts.single.periods.single.usd.remaining,
      135,
    );
    expect(snapshot.toWidgetJson().toString(), isNot(contains('usd')));
    expect(snapshot.toWidgetJson().toString(), isNot(contains('tokens')));
  });
  testWidgets(
    'detail shows total used and remaining USD and explicit missing tokens',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuotaPeriodView(
              period: QuotaPeriod(
                label: '月度美元额度',
                usd: QuotaAmounts.values(total: 150, used: 15),
              ),
            ),
          ),
        ),
      );
      expect(find.text('总额度'), findsOneWidget);
      expect(find.text('已用'), findsOneWidget);
      expect(find.text('剩余'), findsOneWidget);
      expect(find.text('\$135.00'), findsOneWidget);
      expect(find.textContaining('Token 额度'), findsNothing);
      expect(find.textContaining('服务未提供'), findsNothing);
    },
  );
}
