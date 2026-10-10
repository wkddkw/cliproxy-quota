import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import 'connection.dart';
import 'models.dart';

const quotaChannel = MethodChannel('com.wkddkw.cliproxy_quota/cache');
const monitoringJob = 'quota-monitor-v1';

class MonitoringSettings {
  const MonitoringSettings({
    this.enabled = false,
    this.threshold = 5,
    this.mode = 'delta',
    this.interval = 15,
    this.showStatus = false,
    this.hideDetails = false,
  });
  final bool enabled, showStatus, hideDetails;
  final int threshold, interval;
  final String mode;
  MonitoringSettings copyWith({
    bool? enabled,
    int? threshold,
    String? mode,
    int? interval,
    bool? showStatus,
    bool? hideDetails,
  }) => MonitoringSettings(
    enabled: enabled ?? this.enabled,
    threshold: threshold ?? this.threshold,
    mode: mode ?? this.mode,
    interval: interval ?? this.interval,
    showStatus: showStatus ?? this.showStatus,
    hideDetails: hideDetails ?? this.hideDetails,
  );
  Json toJson() => {
    'enabled': enabled,
    'threshold': threshold,
    'mode': mode,
    'interval': interval,
    // Retire the overview even when upgrading persisted settings.
    'showStatus': false,
    'hideDetails': hideDetails,
  };
  factory MonitoringSettings.fromJson(Json j) {
    final threshold = number(j['threshold'])?.toInt() ?? 5;
    final interval = number(j['interval'])?.toInt() ?? 15;
    return MonitoringSettings(
      enabled: j['enabled'] == true,
      threshold: threshold >= 1 && threshold <= 100 ? threshold : 5,
      mode: j['mode'] == 'steps' ? 'steps' : 'delta',
      interval: [15, 30, 60].contains(interval) ? interval : 15,
      showStatus: false,
      hideDetails: j['hideDetails'] == true,
    );
  }
}

abstract class MonitoringScheduler {
  Future<void> schedule(int minutes);
  Future<void> cancel();
}

class AndroidMonitoringScheduler implements MonitoringScheduler {
  @override
  Future<void> schedule(int minutes) => Workmanager().registerPeriodicTask(
    monitoringJob,
    'quota-monitor',
    frequency: Duration(minutes: minutes),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: Constraints(networkType: NetworkType.connected),
  );
  @override
  Future<void> cancel() => Workmanager().cancelByUniqueName(monitoringJob);
}

class Monitoring {
  static MonitoringScheduler scheduler = AndroidMonitoringScheduler();
  static String? startupError;
  static Future<void> configure(MonitoringSettings value) async {
    if (!Platform.isAndroid) return;
    if (value.enabled && startupError != null) throw AppError(startupError!);
    await configureNative(value);
    try {
      if (value.enabled) {
        await scheduler.schedule(value.interval);
      } else {
        await scheduler.cancel();
      }
    } catch (_) {
      await configureNative(value.copyWith(enabled: false));
      throw const AppError('监测未能启动，请重试；当前未开启提醒');
    }
  }

  static Future<void> configureNative(MonitoringSettings value) => quotaChannel
      .invokeMethod<void>('configureMonitoring', jsonEncode(value.toJson()));
  static Json cacheData(QuotaSnapshot snapshot) => {
    'updatedAt': snapshot.updatedAt.toIso8601String(),
    'observedMillis': snapshot.updatedAt.millisecondsSinceEpoch,
    'providers': snapshot.providers
        .where((p) => p.supported)
        .map((p) => p.toWidgetJson())
        .toList(),
    'samples': snapshot.accounts.where((a) => a.supported).expand((a) {
      final accountId = sha256
          .convert(utf8.encode('${a.provider}:${a.id ?? a.name}'))
          .toString()
          .substring(0, 16);
      final periods = a.periods;
      if (periods.isEmpty) {
        return [
          {
            'name': '${a.provider} · $accountId',
            'label': '${a.provider} 账号 ${accountId.substring(0, 4)}',
            'remaining': a.remaining,
            'cycle':
                (a.resetAt == null
                    ? null
                    : (a.resetAt!.millisecondsSinceEpoch ~/ 60000)
                          .toString()) ??
                'unknown',
            'issues': a.reason == null ? 0 : 1,
          },
        ];
      }
      return periods.map(
        (p) => {
          'name': '${a.provider} · $accountId · ${p.id ?? p.label}',
          'label': '${a.provider} 账号 ${accountId.substring(0, 4)} · ${p.label}',
          'remaining': p.remainingPercent,
          // Minute-normalization avoids subsecond jitter in relative resets.
          'cycle': p.end == null
              ? 'unknown'
              : '${p.end!.millisecondsSinceEpoch ~/ 60000}',
          'issues': a.reason == null ? 0 : 1,
        },
      );
    }).toList(),
  };
}
