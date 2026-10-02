import 'json_values.dart';

double? quotaAmount(dynamic value) {
  final parsed = number(value is Map ? value['val'] ?? value['value'] : value);
  return parsed != null && parsed >= 0 ? parsed : null;
}

String windowLabel(double? minutes) {
  if (minutes == null || minutes <= 0) return '主限额';
  if (minutes == 300) return '5 小时限额';
  if (minutes == 1440) return '每日限额';
  if (minutes >= 10080 && minutes < 11520) return '每周限额';
  if (minutes % 1440 == 0) return '${(minutes / 1440).round()} 天限额';
  if (minutes >= 1440) {
    return '${(minutes / 1440).floor()} 天 ${(minutes % 1440 / 60).round()} 小时限额';
  }
  if (minutes % 60 == 0) return '${(minutes / 60).round()} 小时限额';
  if (minutes >= 60) {
    return '${(minutes / 60).floor()} 小时 ${(minutes % 60).round()} 分钟限额';
  }
  return '${minutes.round()} 分钟限额';
}

bool invalidWindow(String value) => RegExp(
  r'^0+(?:\.0+)?(?:m|h|d|s|分钟|小时|天|秒)?$',
).hasMatch(value.trim().toLowerCase());
String bucketWindowLabel(String value) => switch (value.toLowerCase()) {
  '5h' || 'five_hour' || 'five-hour' || '300m' => '5 小时限额',
  'weekly' || '7d' => '每周限额',
  'daily' || '24h' || '1d' => '每日限额',
  'monthly' || 'month' => '月度限额',
  _ => '主限额',
};

class QuotaAmounts {
  const QuotaAmounts({this.total, this.used, this.remaining});
  final double? total;
  final double? used;
  final double? remaining;
  bool get hasData => total != null || used != null || remaining != null;
  factory QuotaAmounts.values({
    dynamic total,
    dynamic used,
    dynamic remaining,
  }) {
    var t = quotaAmount(total),
        u = quotaAmount(used),
        r = quotaAmount(remaining);
    if (t == null && u != null && r != null) t = u + r;
    if (u == null && t != null && r != null && r <= t) u = t - r;
    if (r == null && t != null && u != null) r = (t - u).clamp(0, t).toDouble();
    return QuotaAmounts(total: t, used: u, remaining: r);
  }
  factory QuotaAmounts.fromJson(Json json) => QuotaAmounts.values(
    total: json['total'],
    used: json['used'],
    remaining: json['remaining'],
  );
  Json toJson() => {'total': total, 'used': used, 'remaining': remaining};
}

class QuotaPeriod {
  const QuotaPeriod({
    required this.label,
    this.start,
    this.end,
    this.remainingPercent,
    this.tokens = const QuotaAmounts(),
    this.usd = const QuotaAmounts(),
  });
  final String label;
  final DateTime? start;
  final DateTime? end;
  final double? remainingPercent;
  final QuotaAmounts tokens;
  final QuotaAmounts usd;

  static List<QuotaPeriod> fromGrok(Json config) {
    final raw = config['currentPeriod'] ?? config['current_period'];
    final period = raw is Map ? Json.from(raw) : <String, dynamic>{};
    final credits = number(
      config['creditUsagePercent'] ?? config['credit_usage_percent'],
    );
    final weekly =
        credits != null || '${period['type']}'.toLowerCase().contains('weekly');
    final result = <QuotaPeriod>[];
    if (weekly) {
      result.add(
        QuotaPeriod(
          label: '每周限额',
          start: timestamp(period['start']),
          end: timestamp(period['end']),
          remainingPercent: credits != null && credits >= 0
              ? (100 - credits).clamp(0, 100).toDouble()
              : null,
          tokens: _explicitAmounts(config, 'tokens'),
        ),
      );
    }
    final limit = quotaAmount(
      config['monthlyLimit'] ?? config['monthly_limit'],
    );
    final used = quotaAmount(config['used']);
    if (limit != null || used != null) {
      result.add(
        QuotaPeriod(
          label: '月度美元额度',
          start: timestamp(
            config['billingPeriodStart'] ?? config['billing_period_start'],
          ),
          end: timestamp(
            config['billingPeriodEnd'] ?? config['billing_period_end'],
          ),
          usd: QuotaAmounts.values(
            total: limit == null ? null : limit / 100,
            used: used == null ? null : used / 100,
          ),
          tokens: weekly
              ? const QuotaAmounts()
              : _explicitAmounts(config, 'tokens'),
        ),
      );
    }
    if (!weekly && result.isEmpty) {
      result.add(
        QuotaPeriod(
          label: 'Grok 主窗口',
          tokens: _explicitAmounts(config, 'tokens'),
        ),
      );
    }
    return result;
  }

  static QuotaAmounts _explicitAmounts(Json raw, String unit) {
    final nested = raw[unit];
    if (nested is Map) return QuotaAmounts.fromJson(Json.from(nested));
    final reportedUnit = '${raw['unit'] ?? ''}'.toLowerCase();
    final matches = unit == 'tokens'
        ? reportedUnit == 'tokens' || reportedUnit == 'token'
        : reportedUnit == 'usd' ||
              '${raw['currency'] ?? ''}'.toUpperCase() == 'USD';
    if (matches) {
      return QuotaAmounts.values(
        total: raw['total'] ?? raw['limit'],
        used: raw['used'],
        remaining: raw['remaining'],
      );
    }
    String camel(String field) =>
        '$unit${field[0].toUpperCase()}${field.substring(1)}';
    dynamic read(String field) =>
        raw['${unit}_$field'] ?? raw[camel(field)] ?? raw['${field}_$unit'];
    return QuotaAmounts.values(
      total: read('total'),
      used: read('used'),
      remaining: read('remaining'),
    );
  }

  static List<QuotaPeriod> fromPlugin(Json data) {
    final result = <QuotaPeriod>[];
    if (data['groups'] is List) {
      for (final group in data['groups']) {
        if (group is! Map || group['buckets'] is! List) continue;
        for (final raw in group['buckets']) {
          if (raw is! Map) continue;
          final bucket = Json.from(raw);
          if (invalidWindow('${bucket['window'] ?? ''}')) continue;
          final fraction = number(
            bucket['remainingFraction'] ?? bucket['remaining_fraction'],
          );
          result.add(
            QuotaPeriod(
              label:
                  '${group['displayName'] ?? group['display_name'] ?? '限额'} · ${bucketWindowLabel('${bucket['window'] ?? ''}')}',
              start: timestamp(bucket['startTime'] ?? bucket['start_time']),
              end: timestamp(bucket['resetTime'] ?? bucket['reset_time']),
              remainingPercent:
                  fraction != null && fraction >= 0 && fraction <= 1
                  ? fraction * 100
                  : null,
              tokens: _explicitAmounts(bucket, 'tokens'),
              usd: _explicitAmounts(bucket, 'usd'),
            ),
          );
        }
      }
    }
    // Normalized plugin summaries can report absolute amounts without a window.
    // Keep these separate; never attach monthly money to a five-hour quota.
    if (data['summary'] is List) {
      final tokens = <String, double>{}, usd = <String, double>{};
      for (final raw in data['summary']) {
        if (raw is! Map) continue;
        final value = quotaAmount(raw['value']);
        if (value == null) continue;
        final key = '${raw['key'] ?? ''}'.toLowerCase();
        final unit = '${raw['unit'] ?? ''}'.toLowerCase();
        final currency = '${raw['currency'] ?? ''}'.toUpperCase();
        final isToken =
            unit == 'tokens' ||
            unit == 'token' ||
            (key.contains('token') &&
                currency.isEmpty &&
                unit != 'usd' &&
                raw['format'] != 'currency');
        final isUsd = currency == 'USD' || unit == 'usd';
        final field = key.contains('remaining') || key.endsWith('_balance')
            ? 'remaining'
            : key.contains('total') || key.contains('limit')
            ? 'total'
            : key.contains('used') || key.contains('spent') || key == 'charged'
            ? 'used'
            : null;
        if (field == null) continue;
        if (isToken) tokens[field] = value;
        if (isUsd) usd[field] = value;
      }
      if (tokens.isNotEmpty || usd.isNotEmpty) {
        result.add(
          QuotaPeriod(
            label: '服务额度明细（周期未提供）',
            tokens: QuotaAmounts.fromJson(tokens),
            usd: QuotaAmounts.fromJson(usd),
          ),
        );
      }
    }
    return result;
  }

  Json toJson() => {
    'label': label,
    'start': start?.toIso8601String(),
    'end': end?.toIso8601String(),
    'remainingPercent': remainingPercent,
    'tokens': tokens.toJson(),
    'usd': usd.toJson(),
  };
  factory QuotaPeriod.fromJson(Json json) => QuotaPeriod(
    label: json['label'] as String,
    start: timestamp(json['start']),
    end: timestamp(json['end']),
    remainingPercent: number(json['remainingPercent']),
    tokens: QuotaAmounts.fromJson(Json.from(json['tokens'] ?? {})),
    usd: QuotaAmounts.fromJson(Json.from(json['usd'] ?? {})),
  );
}
