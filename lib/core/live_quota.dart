import 'models.dart';
import 'quota_details.dart';

/// Parses read-only OAuth usage responses, not passive response headers.
AccountQuota? liveQuota(AccountQuota account, Json payload, DateTime now) {
  final windows = <({QuotaWindow value, String label})>[];
  void add(
    Json row,
    double? minutes,
    String label,
    String usedKey,
    String resetKey,
  ) {
    if (minutes != null && minutes <= 0) return;
    final used = number(row[usedKey]);
    if (used == null || used < 0 || used > 100) return;
    final seconds = number(
      row['reset_after_seconds'] ?? row['resetAfterSeconds'],
    );
    final reset =
        timestamp(row[resetKey] ?? row['resetAt']) ??
        (seconds != null && seconds >= 0
            ? now.add(Duration(milliseconds: (seconds * 1000).round()))
            : null);
    windows.add((value: QuotaWindow(100 - used, minutes, reset), label: label));
  }

  if (account.provider == 'GPT') {
    final limit = payload['rate_limit'] ?? payload['rateLimit'];
    if (limit is! Map) return null;
    for (final raw in [
      limit['primary_window'] ?? limit['primaryWindow'],
      limit['secondary_window'] ?? limit['secondaryWindow'],
    ]) {
      if (raw is! Map) continue;
      final row = Json.from(raw);
      final seconds = number(
        row['limit_window_seconds'] ?? row['limitWindowSeconds'],
      );
      final minutes = seconds == null ? null : seconds / 60;
      add(
        {...row, 'used_percent': row['used_percent'] ?? row['usedPercent']},
        minutes,
        windowLabel(minutes),
        'used_percent',
        'reset_at',
      );
    }
  } else if (account.provider == 'Claude') {
    const keys = {
      'five_hour': (300.0, '5 小时限额'),
      'seven_day': (10080.0, '每周限额'),
      'seven_day_oauth_apps': (10080.0, 'OAuth 应用每周限额'),
      'seven_day_opus': (10080.0, 'Opus 每周限额'),
      'seven_day_sonnet': (10080.0, 'Sonnet 每周限额'),
      'seven_day_cowork': (10080.0, 'Cowork 每周限额'),
    };
    for (final entry in keys.entries) {
      final row = payload[entry.key];
      if (row is Map) {
        add(
          Json.from(row),
          entry.value.$1,
          entry.value.$2,
          'utilization',
          'resets_at',
        );
      }
    }
  }
  if (windows.isEmpty) return null;
  final chosen =
      windows.where((w) => w.value.minutes == 300).firstOrNull ?? windows.first;
  return AccountQuota(
    provider: account.provider,
    name: account.name,
    remaining: chosen.value.remaining,
    resetAt: chosen.value.resetAt,
    windowMinutes: chosen.value.minutes,
    observedAt: now,
    queried: true,
    periods: windows
        .map(
          (w) => QuotaPeriod(
            label: w.label,
            end: w.value.resetAt,
            remainingPercent: w.value.remaining,
          ),
        )
        .toList(),
  );
}
