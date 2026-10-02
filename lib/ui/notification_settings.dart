import 'package:flutter/material.dart';
import '../core/connection.dart';
import '../core/monitoring.dart';
import '../core/storage.dart';

class NotificationSettingsPanel extends StatefulWidget {
  const NotificationSettingsPanel({super.key, required this.storage});
  final AppStorage storage;
  @override
  State<NotificationSettingsPanel> createState() =>
      _NotificationSettingsPanelState();
}

class _NotificationSettingsPanelState extends State<NotificationSettingsPanel>
    with WidgetsBindingObserver {
  late MonitoringSettings value;
  Map<String, dynamic> status = {};
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    value = widget.storage.monitoringSettings;
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    try {
      final response = await quotaChannel
          .invokeMapMethod<String, dynamic>('monitoringStatus')
          .timeout(const Duration(seconds: 5));
      if (mounted) setState(() => status = response ?? {});
    } catch (_) {
      if (mounted) setState(() => message = '无法检查通知状态，请尝试系统通知设置');
    }
  }

  Future<void> save(MonitoringSettings next) async {
    setState(() => busy = true);
    try {
      if (next.enabled && widget.storage.settings == null) {
        throw const AppError('请先保存服务器连接');
      }
      if (next.enabled && !value.enabled) {
        final allowed =
            await quotaChannel.invokeMethod<bool>(
              'requestNotificationPermission',
            ) ==
            true;
        if (!allowed) throw const AppError('系统通知未开启，请在通知设置中允许提醒');
      }
      await widget.storage.saveMonitoring(next);
      if (mounted) {
        setState(() {
          value = next;
          message = next.enabled ? '通知设置已保存，首次有效检查建立提醒基准' : '消耗提醒已关闭';
        });
      }
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          value = widget.storage.monitoringSettings;
          message = e is AppError ? e.message : '通知设置未能保存，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> test() async {
    setState(() => busy = true);
    try {
      final allowed =
          await quotaChannel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ==
          true;
      if (!allowed) throw const AppError('请先在系统通知设置中允许通知');
      final sent =
          await quotaChannel.invokeMethod<bool>('testNotification') == true;
      if (mounted) {
        setState(
          () =>
              message = sent ? '已发送测试通知；悬浮显示和声音由系统通知设置控制' : '系统未允许消耗提醒，请检查通知设置',
        );
      }
      await load();
    } catch (e) {
      if (mounted) {
        setState(() => message = e is AppError ? e.message : '测试通知发送失败');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    margin: const EdgeInsets.only(top: 20),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '限额通知',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('开启消耗提醒'),
            subtitle: const Text('按供应商最低剩余百分比变化提醒'),
            value: value.enabled,
            onChanged: busy
                ? null
                : (enabled) => save(value.copyWith(enabled: enabled)),
          ),
          Text('每下降 ${value.threshold} 个百分点提醒一次'),
          Slider(
            value: value.threshold.toDouble(),
            min: 1,
            max: 100,
            divisions: 99,
            label: '${value.threshold}%',
            onChanged: busy
                ? null
                : (n) => setState(
                    () => value = value.copyWith(threshold: n.round()),
                  ),
          ),
          DropdownButtonFormField<String>(
            initialValue: value.mode,
            decoration: const InputDecoration(labelText: '提醒方式'),
            items: const [
              DropdownMenuItem(value: 'delta', child: Text('从上次基准累计消耗')),
              DropdownMenuItem(value: 'steps', child: Text('已用经过固定百分比刻度')),
            ],
            onChanged: busy
                ? null
                : (mode) => setState(() => value = value.copyWith(mode: mode)),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            initialValue: value.interval,
            decoration: const InputDecoration(labelText: '后台检查间隔'),
            items: const [
              DropdownMenuItem(value: 15, child: Text('约每 15 分钟')),
              DropdownMenuItem(value: 30, child: Text('约每 30 分钟')),
              DropdownMenuItem(value: 60, child: Text('约每小时')),
            ],
            onChanged: busy
                ? null
                : (n) => setState(() => value = value.copyWith(interval: n)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('通知栏显示限额概览'),
            subtitle: const Text('静默更新，可划掉；关闭后隐藏概览'),
            value: value.showStatus,
            onChanged: busy
                ? null
                : (enabled) => setState(
                    () => value = value.copyWith(showStatus: enabled),
                  ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('隐藏通知内容'),
            subtitle: const Text('通知只提示变化，具体限额在 App 查看'),
            value: value.hideDetails,
            onChanged: busy
                ? null
                : (enabled) => setState(
                    () => value = value.copyWith(hideDetails: enabled),
                  ),
          ),
          FilledButton.tonal(
            onPressed: busy ? null : () => save(value),
            child: const Text('保存通知设置'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : test,
                child: const Text('发送测试通知'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await quotaChannel.invokeMethod<void>(
                            'openNotificationSettings',
                          );
                        } catch (_) {
                          if (mounted) {
                            setState(() => message = '无法打开系统设置，请从应用信息进入通知设置');
                          }
                        }
                      },
                child: const Text('系统通知设置'),
              ),
            ],
          ),
          if (value.enabled && status['allowed'] == false)
            const Text('系统已关闭消耗通知，检查仍在运行。请打开通知权限或关闭监测。'),
          if (value.enabled &&
              value.showStatus &&
              status['summaryAllowed'] == false)
            const Text('系统已关闭概览通知渠道，请检查通知设置。'),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message!),
            ),
          if (value.enabled && (status['lastCheck'] as num? ?? 0) > 0)
            Text(
              '最近检查：${_time((status['lastCheck'] as num).toInt())}',
              style: const TextStyle(fontSize: 12),
            ),
          if (value.enabled && '${status['lastError'] ?? ''}'.isNotEmpty)
            Text(
              '${status['lastError']}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            '后台检查由系统调度，省电模式、强行停止 App 或 VPN 断开可能导致延迟。打开 App 刷新也会检查。普通通知不保证进入 ColorOS 流体云；悬浮提醒和声音受系统设置、勿扰模式控制。',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
        ],
      ),
    ),
  );
  String _time(int millis) {
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    String p(int n) => '$n'.padLeft(2, '0');
    return '${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }
}
