import 'dart:math' as math;
import 'json_values.dart';
import 'quota_details.dart';
export 'json_values.dart';

String providerName(String raw) => switch (raw.toLowerCase()) {
  'codex' || 'openai' || 'openai-compatibility' || 'gpt' => 'GPT',
  'claude' || 'anthropic' => 'Claude',
  'grok' || 'xai' => 'Grok',
  'gemini' || 'gemini-cli' => 'Gemini',
  '' => '其他',
  _ => raw,
};

class QuotaWindow {
  const QuotaWindow(this.remaining, this.minutes, this.resetAt);
  final double remaining;
  final double? minutes;
  final DateTime? resetAt;
}

class AccountQuota {
  const AccountQuota({
    required this.provider,
    required this.name,
    this.remaining,
    this.resetAt,
    this.observedAt,
    this.reason,
    this.windowMinutes,
    this.supported = true,
    this.periods = const [],
  });
  final String provider;
  final String name;
  final double? remaining;
  final DateTime? resetAt;
  final DateTime? observedAt;
  final String? reason;
  final double? windowMinutes;
  final bool supported;
  final List<QuotaPeriod> periods;

  AccountQuota withPeriods(List<QuotaPeriod> value) => AccountQuota(
    provider: provider,
    name: name,
    remaining: remaining,
    resetAt: resetAt,
    observedAt: observedAt,
    reason: reason,
    windowMinutes: windowMinutes,
    supported: supported,
    periods: value,
  );

  AccountQuota withBillingDetails(AccountQuota? monthly) {
    if (monthly == null || !monthly.periods.any((p) => p.usd.hasData)) {
      return this;
    }
    return withPeriods([
      ...periods.where((p) => !p.usd.hasData),
      ...monthly.periods.where((p) => p.usd.hasData),
    ]);
  }

  AccountQuota? withGrokBilling(Json config) {
    final period = config['currentPeriod'] ?? config['current_period'];
    final periodMap = period is Map ? Json.from(period) : <String, dynamic>{};
    final type = '${periodMap['type'] ?? ''}'.toLowerCase();
    final credits = number(
      config['creditUsagePercent'] ?? config['credit_usage_percent'],
    );
    final weekly =
        credits != null ||
        type.contains('weekly') ||
        (config['productUsage'] is List &&
            (config['productUsage'] as List).isNotEmpty);
    double? amount(dynamic value) =>
        number(value is Map ? value['val'] : value);
    final limit = amount(config['monthlyLimit'] ?? config['monthly_limit']);
    final used = amount(config['used']);
    if (!weekly && limit == null && used == null && !type.contains('monthly')) {
      return null;
    }
    final percent = weekly
        ? credits
        : limit != null && limit > 0 && used != null && used >= 0
        ? used / limit * 100
        : null;
    final start = timestamp(
      weekly
          ? periodMap['start'] ??
                config['billingPeriodStart'] ??
                config['billing_period_start']
          : config['billingPeriodStart'] ?? config['billing_period_start'],
    );
    final end = timestamp(
      weekly
          ? periodMap['end'] ??
                config['billingPeriodEnd'] ??
                config['billing_period_end']
          : config['billingPeriodEnd'] ?? config['billing_period_end'],
    );
    final remaining = percent != null && percent >= 0
        ? (100 - percent).clamp(0, 100).toDouble()
        : null;
    return AccountQuota(
      provider: provider,
      name: name,
      remaining: remaining,
      resetAt: end,
      observedAt: DateTime.now().toUtc(),
      supported: true,
      periods: QuotaPeriod.fromGrok(config),
      windowMinutes: start != null && end != null && end.isAfter(start)
          ? end.difference(start).inSeconds / 60
          : weekly
          ? 10080
          : null,
      reason: remaining == null ? '服务未提供当前窗口的剩余百分比' : null,
    );
  }

  factory AccountQuota.fromApi(Json file) {
    final rawProvider = "${file['provider'] ?? file['type'] ?? ''}"
        .toLowerCase();
    final passiveSupported = rawProvider == 'codex' || rawProvider == 'claude';
    final provider = providerName('${file['provider'] ?? file['type'] ?? ''}');
    final name = '${file['email'] ?? file['name'] ?? file['id'] ?? '未命名认证文件'}';
    final quota = file['quota'] is Map
        ? Json.from(file['quota'])
        : <String, dynamic>{};
    final observed = timestamp(quota['observed_at']);
    final signals = quota['signals'] is Map
        ? Json.from(
            quota['signals'],
          ).map((key, value) => MapEntry(key.toLowerCase(), value))
        : <String, dynamic>{};
    final windows = <QuotaWindow>[];
    DateTime? resetFor(String prefix) {
      final absolute = timestamp(
        signals['$prefix-reset-at'] ?? signals['$prefix-reset'],
      );
      if (absolute != null) return absolute;
      final seconds = number(signals['$prefix-reset-after-seconds']);
      return seconds != null && observed != null
          ? observed.add(Duration(seconds: seconds.round()))
          : null;
    }

    if (provider == 'GPT') {
      for (final prefix in ['x-codex-primary', 'x-codex-secondary']) {
        final used = number(signals['$prefix-used-percent']);
        if (used != null) {
          windows.add(
            QuotaWindow(
              (100 - used).clamp(0, 100).toDouble(),
              number(signals['$prefix-window-minutes']),
              resetFor(prefix),
            ),
          );
        }
      }
    }
    if (provider == 'Claude') {
      for (final pair in [('5h', 300.0), ('7d', 10080.0)]) {
        final prefix = 'anthropic-ratelimit-unified-${pair.$1}';
        final used = number(signals['$prefix-utilization']);
        if (used != null) {
          windows.add(
            QuotaWindow(
              (100 - used * 100).clamp(0, 100).toDouble(),
              pair.$2,
              resetFor(prefix),
            ),
          );
        }
      }
    }
    // Some server extensions return explicit windows; never infer a percentage
    // from cooldown flags, retry delays, or an unavailable state.
    if (windows.isEmpty && quota['windows'] is List) {
      for (final raw in quota['windows']) {
        if (raw is! Map) continue;
        final value = number(raw['remaining_percent']);
        if (value != null) {
          windows.add(
            QuotaWindow(
              value.clamp(0, 100).toDouble(),
              number(raw['window_minutes']),
              timestamp(raw['reset_at']),
            ),
          );
        }
      }
    }
    final chosen =
        windows.where((w) => w.minutes == 300).firstOrNull ??
        windows.firstOrNull;
    String? reason;
    if (file['disabled'] == true || file['status'] == 'disabled') {
      reason = '已禁用';
    } else if (file['unavailable'] == true || file['status'] == 'error') {
      final message = '${file['status_message'] ?? ''}'.trim();
      // Do not persist arbitrary upstream errors which may include credentials.
      reason = message.contains('401')
          ? '401 · 认证失效'
          : message.contains('403')
          ? '403 · 无权访问'
          : '账号不可用 · 探测失败';
    } else if (chosen == null) {
      reason = file['supports_quota'] == true || passiveSupported
          ? '服务尚未返回限额数据'
          : '暂不支持';
    }
    return AccountQuota(
      provider: provider,
      periods: windows
          .map(
            (w) => QuotaPeriod(
              label: windowLabel(w.minutes),
              remainingPercent: w.remaining,
              end: w.resetAt,
            ),
          )
          .toList(),
      name: name,
      remaining: chosen?.remaining,
      resetAt: chosen?.resetAt,
      observedAt: observed,
      windowMinutes: chosen?.minutes,
      reason: reason,
      supported:
          chosen != null || file['supports_quota'] == true || passiveSupported,
    );
  }

  AccountQuota withProbe({Json? data, String? failure, bool available = true}) {
    final windows = <QuotaWindow>[];
    if (data?['groups'] is List) {
      for (final group in data!['groups']) {
        if (group is! Map || group['buckets'] is! List) continue;
        for (final bucket in group['buckets']) {
          if (bucket is! Map) continue;
          final fraction = number(
            bucket['remainingFraction'] ?? bucket['remaining_fraction'],
          );
          if (fraction == null || fraction < 0 || fraction > 1) continue;
          final window = '${bucket['window'] ?? ''}'.toLowerCase().replaceAll(
            ' ',
            '',
          );
          final minutes = switch (window) {
            '5h' ||
            '5hour' ||
            '5hours' ||
            'five_hour' ||
            'five-hour' ||
            '300m' => 300.0,
            'daily' || '24h' || '1d' => 1440.0,
            'weekly' || '7d' => 10080.0,
            _ => null,
          };
          windows.add(
            QuotaWindow(
              fraction * 100,
              minutes,
              timestamp(bucket['resetTime'] ?? bucket['reset_time']),
            ),
          );
        }
      }
    }
    final preferred = windows.where((w) => w.minutes == 300).toList();
    final candidates = preferred.isNotEmpty ? preferred : windows;
    final chosen = candidates.isEmpty
        ? null
        : candidates.reduce((a, b) => a.remaining <= b.remaining ? a : b);
    if (chosen == null && remaining != null) {
      return data == null
          ? this
          : withPeriods([...periods, ...QuotaPeriod.fromPlugin(data)]);
    }
    return AccountQuota(
      provider: provider,
      periods: data == null ? periods : QuotaPeriod.fromPlugin(data),
      name: name,
      remaining: chosen?.remaining,
      resetAt: chosen?.resetAt,
      observedAt: chosen == null ? observedAt : DateTime.now().toUtc(),
      windowMinutes: chosen?.minutes,
      reason: chosen != null
          ? null
          : failure ?? (available ? '服务尚未返回限额数据' : '暂不支持'),
      supported: available,
    );
  }

  Json toJson() => {
    'provider': provider,
    'name': name,
    'remaining': remaining,
    'resetAt': resetAt?.toIso8601String(),
    'observedAt': observedAt?.toIso8601String(),
    'reason': reason,
    'windowMinutes': windowMinutes,
    'supported': supported,
    'periods': periods.map((period) => period.toJson()).toList(),
  };
  factory AccountQuota.fromJson(Json json) => AccountQuota(
    provider: json['provider'] as String,
    name: json['name'] as String,
    remaining: number(json['remaining']),
    resetAt: timestamp(json['resetAt']),
    observedAt: timestamp(json['observedAt']),
    reason: json['reason'] as String?,
    windowMinutes: number(json['windowMinutes']),
    supported: json['supported'] != false,
    periods: (json['periods'] is List ? json['periods'] as List : const [])
        .whereType<Map>()
        .map((p) => QuotaPeriod.fromJson(Json.from(p)))
        .toList(),
  );
}

class ProviderQuota {
  ProviderQuota(this.name, this.accounts);
  final String name;
  final List<AccountQuota> accounts;
  int get issues => accounts.where((a) => a.reason != null).length;
  bool get supported => accounts.any((a) => a.supported);
  // A missing or unavailable account prevents a misleading pool percentage.
  double? get remaining =>
      accounts.any((a) => a.remaining == null || a.reason != null)
      ? null
      : accounts.map((a) => a.remaining!).reduce(math.min);
  String get symbol => switch (name) {
    'GPT' => 'G',
    'Claude' => '✳',
    'Grok' => '𝕏',
    _ => name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
  };
  Json toWidgetJson() => {
    'name': name,
    'symbol': symbol,
    'count': accounts.length,
    'remaining': remaining,
    'issues': issues,
  };
}

class QuotaSnapshot {
  const QuotaSnapshot(this.updatedAt, this.accounts);
  final DateTime updatedAt;
  final List<AccountQuota> accounts;
  List<ProviderQuota> get providers {
    final groups = <String, List<AccountQuota>>{};
    for (final account in accounts) {
      groups.putIfAbsent(account.provider, () => []).add(account);
    }
    final names = groups.keys.toList()
      ..sort((a, b) {
        const order = ['GPT', 'Claude', 'Grok'];
        final ai = order.indexOf(a), bi = order.indexOf(b);
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi) != 0
            ? (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi)
            : a.compareTo(b);
      });
    return names.map((name) => ProviderQuota(name, groups[name]!)).toList();
  }

  Json toJson() => {
    'updatedAt': updatedAt.toIso8601String(),
    'accounts': accounts.map((a) => a.toJson()).toList(),
  };
  Json toWidgetJson() => {
    'updatedAt': updatedAt.toIso8601String(),
    'providers': providers
        .where((p) => p.supported)
        .map((p) => p.toWidgetJson())
        .toList(),
  };
  factory QuotaSnapshot.fromJson(Json json) => QuotaSnapshot(
    DateTime.parse(json['updatedAt'] as String),
    (json['accounts'] as List)
        .map((a) => AccountQuota.fromJson(Json.from(a)))
        .toList(),
  );
}
