import 'dart:async';
import 'package:flutter/material.dart';
import '../core/connection.dart';
import '../core/monitoring.dart';
import '../core/storage.dart';
import 'help_button.dart';

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
  Timer? poll;
  @override
  void initState() {
    super.initState();
    value = widget.storage.monitoringSettings;
    WidgetsBinding.instance.addObserver(this);
    load();
    poll = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() {
    poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  void notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> load() async {
    try {
      await widget.storage.preferences.reload();
      final response = await quotaChannel
          .invokeMapMethod<String, dynamic>('monitoringStatus')
          .timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() {
          status = response ?? {};
          if (status['enabled'] == false) {
            value = value.copyWith(enabled: false);
          }
        });
      }
    } catch (_) {
      /* A transient status read must not fill the settings page. */
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
      if (mounted) setState(() => value = next);
      notice(next.enabled ? '已保存定时刷新设置' : '已关闭定时刷新');
      await load();
    } catch (e) {
      if (mounted) setState(() => value = widget.storage.monitoringSettings);
      notice(e is AppError ? e.message : '设置未能保存，请重试');
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
      notice(sent ? '已发送测试通知' : '系统未允许消耗提醒，请检查通知设置');
      await load();
    } catch (e) {
      notice(e is AppError ? e.message : '测试通知发送失败');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openSettings(String method) async {
    try {
      await quotaChannel.invokeMethod<void>(method);
    } catch (_) {
      notice('请从系统应用信息进入相应设置');
    }
  }

  Future<void> help() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('定时刷新与提醒'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '后台按所选间隔检查，不显示常驻通知。系统省电或厂商后台限制可能延后检查；VPN 和服务器需保持可访问。\n\n默认累计下降 5 个百分点提醒一次，例如 80% → 75%。首次检查建立基准，周期重置或额度回升不会误报。固定刻度模式在已用比例跨过指定刻度时提醒。\n\n隐藏通知内容时只提示额度变化，详情在 App 查看。',
            ),
            if (status['allowed'] == false) const Text('\n系统通知当前未开启。'),
            if (status['batteryOptimized'] == true)
              const Text('\n系统电池优化已开启，后台检查可能延迟。'),
            TextButton(
              onPressed: () => openSettings('openNotificationSettings'),
              child: const Text('系统通知设置'),
            ),
            TextButton(
              onPressed: () => openSettings('openBatterySettings'),
              child: const Text('后台与电池设置'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    margin: const EdgeInsets.only(top: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '定时刷新与通知',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '定时刷新与提醒说明',
                onPressed: help,
                icon: const Icon(Icons.help_outline, size: 20),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('定时刷新'),
            value: value.enabled,
            onChanged: busy
                ? null
                : (enabled) => save(value.copyWith(enabled: enabled)),
          ),
          DropdownButtonFormField<int>(
            initialValue: value.interval,
            decoration: const InputDecoration(labelText: '刷新间隔'),
            items: const [
              DropdownMenuItem(value: 15, child: Text('15 分钟')),
              DropdownMenuItem(value: 30, child: Text('30 分钟')),
              DropdownMenuItem(value: 60, child: Text('1 小时')),
            ],
            onChanged: busy
                ? null
                : (n) => setState(() => value = value.copyWith(interval: n)),
          ),
          const SizedBox(height: 16),
          Text('每消耗 ${value.threshold}% 提醒'),
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
              DropdownMenuItem(value: 'delta', child: Text('累计消耗')),
              DropdownMenuItem(value: 'steps', child: Text('固定刻度')),
            ],
            onChanged: busy
                ? null
                : (mode) => setState(() => value = value.copyWith(mode: mode)),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('隐藏通知内容'),
            value: value.hideDetails,
            onChanged: busy
                ? null
                : (hide) =>
                      setState(() => value = value.copyWith(hideDetails: hide)),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: busy ? null : () => save(value),
                child: const Text('保存设置'),
              ),
              TextButton(
                onPressed: busy ? null : test,
                child: const Text('测试通知'),
              ),
            ],
          ),
          if (value.enabled)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      status['checking'] == true
                          ? '正在检查…'
                          : '最近检查：${_time((status['lastBackgroundCheck'] as num? ?? 0).toInt())}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if ('${status['lastBackgroundError'] ?? ''}'.isNotEmpty)
                    HelpButton(
                      title: '检查失败',
                      text: '${status['lastBackgroundError']}',
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
  String _time(int millis) {
    if (millis <= 0) return '尚未检查';
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    String p(int n) => '$n'.padLeft(2, '0');
    return '${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }
}
