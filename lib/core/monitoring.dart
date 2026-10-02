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
    'showStatus': showStatus,
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
      showStatus: j['showStatus'] == true,
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
      throw const AppError('后台检查未能启动，请重试；当前未开启提醒');
    }
  }

  static Future<void> configureNative(MonitoringSettings value) => quotaChannel
      .invokeMethod<void>('configureMonitoring', jsonEncode(value.toJson()));
  static Json cacheData(QuotaSnapshot snapshot) => {
    'updatedAt': snapshot.updatedAt.toIso8601String(),
    'observedMillis': snapshot.updatedAt.millisecondsSinceEpoch,
    'providers': snapshot.providers.where((p) => p.supported).map((p) {
      final cycles =
          p.accounts
              .map(
                (a) => jsonEncode([
                  a.name,
                  a.resetAt?.toIso8601String(),
                  a.windowMinutes,
                ]),
              )
              .toList()
            ..sort();
      return {
        ...p.toWidgetJson(),
        'cycle': sha256.convert(utf8.encode(jsonEncode(cycles))).toString(),
      };
    }).toList(),
  };
}
