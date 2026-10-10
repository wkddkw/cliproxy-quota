import 'package:flutter_test/flutter_test.dart';
import 'package:cliproxy_quota/core/usage_format.dart';

void main() {
  test('compact decimal units round and promote cleanly', () {
    expect(compactUsage(681580000), '681.58M');
    expect(compactUsage(649320000), '649.32M');
    expect(compactUsage(965640), '965.64K');
    expect(compactUsage(1000000000), '1B');
    expect(compactUsage(999999), '1M');
    expect(compactUsage(1200), '1.2K');
    expect(compactUsage(0), '0');
    expect(compactUsage(null), '—');
    expect(compactUsage(double.nan), '—');
    expect(exactUsage(1234567), '1,234,567');
  });
  test('partial positive cost is visible, not a dash or falsely complete', () {
    expect(
      usageCost({'cost_usd': 12.34, 'cost_available': false}),
      '\$12.340（部分）',
    );
    expect(usageCost({'cost_usd': 0, 'cost_available': true}), '\$0');
    expect(usageCost({'cost_usd': 0, 'cost_available': false}), '未完整计价');
    expect(usageCost({}), '未返回费用');
  });
  test('daily aggregation preserves server calendar date and partial cost', () {
    final rows = dailyUsage([
      {
        'bucket': '2026-10-09T23:00:00-05:00',
        'total_tokens': 2000,
        'cache_read_tokens': 1000,
        'cost_usd': 1.2,
        'cost_available': true,
      },
      {
        'bucket': '2026-10-09T22:00:00-05:00',
        'total_tokens': 3000,
        'cache_read_tokens': 2000,
        'cost_usd': 2.3,
        'cost_available': false,
      },
    ]);
    expect(rows.single['day'], '2026-10-09');
    expect(rows.single['total_tokens'], 5000);
    expect(rows.single['cache_read_tokens'], 3000);
    expect(rows.single['cost_usd'], 3.5);
    expect(rows.single['cost_available'], false);
  });
}
