import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/storage.dart';

class WidgetSetupPanel extends StatefulWidget {
  const WidgetSetupPanel({super.key});
  @override
  State<WidgetSetupPanel> createState() => _WidgetSetupPanelState();
}

class _WidgetSetupPanelState extends State<WidgetSetupPanel>
    with WidgetsBindingObserver {
  Map<String, dynamic> status = {};
  String? message;
  bool busy = false;
  bool pending = false;
  int baseline = 0;
  Timer? confirmation;
  bool? get supported => status['pinSupported'] as bool?;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    confirmation?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load({bool reportMissing = false}) async {
    try {
      final value = await AppStorage.channel
          .invokeMapMethod<String, dynamic>('widgetStatus')
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        status = value ?? {};
        final count = (status['widgetCount'] as num?)?.toInt() ?? 0;
        if (pending && count > baseline) {
          pending = false;
          confirmation?.cancel();
          message = '系统已创建桌面小组件（共 $count 个）。';
        } else if (pending && reportMissing) {
          pending = false;
          message = '尚未检测到新小组件。若没有系统弹窗，请使用桌面的小组件菜单手动添加。';
        }
      });
    } catch (_) {
      if (mounted) setState(() => message = '无法检查当前桌面，请查看下方手动添加说明。');
    }
  }

  Future<void> pin() async {
    setState(() {
      busy = true;
      message = '正在向系统桌面请求添加…';
    });
    // Always allow a tap, even if a launcher reports no pin support. The user
    // must receive an explanation rather than an inert disabled button.
    try {
      await load();
      baseline = (status['widgetCount'] as num?)?.toInt() ?? 0;
      final requested =
          await AppStorage.channel
              .invokeMethod<bool>('pinWidget')
              .timeout(const Duration(seconds: 8)) ==
          true;
      if (!mounted) return;
      setState(() {
        pending = requested;
        message = requested
            ? '请求已发出，等待系统确认；尚未确认添加成功。'
            : '当前桌面未接受直接添加请求。请长按桌面空白处，从“小组件”菜单手动添加。';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message!)));
      confirmation?.cancel();
      if (requested) {
        confirmation = Timer(
          const Duration(seconds: 12),
          () => load(reportMissing: true),
        );
      } else {
        await manualHelp();
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => message = '系统桌面未在 8 秒内返回添加结果。请尝试手动添加，并复制诊断信息。');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message!)));
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => message = '系统添加请求失败（${e.code}）。请尝试手动添加，并复制诊断信息。');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message!)));
      }
    } catch (_) {
      if (mounted) setState(() => message = '添加请求失败，请尝试手动添加并复制诊断信息。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> manualHelp() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('从系统桌面手动添加'),
      content: const Text(
        '长按桌面空白处 → 小组件，查找“CLIProxy 限额”。如果进入的是厂商卡片中心，请同时检查是否有“Android 小组件”或普通小组件入口。\n\n若仍找不到，请返回这里复制诊断信息。标准小组件不需要照片或定位权限。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            try {
              await AppStorage.channel.invokeMethod<void>('openHome');
            } catch (_) {}
          },
          child: const Text('前往桌面'),
        ),
      ],
    ),
  );

  String get diagnostic => [
    'CLIProxy 限额 v0.1.2',
    '设备：${status['device'] ?? '未取得'}',
    'Android：${status['androidVersion'] ?? '未知'} / API ${status['apiLevel'] ?? '未知'}',
    '桌面：${status['launcher'] ?? '未知'}',
    '组件注册：${status['providerRegistered'] ?? '未知'}',
    '支持直接添加：${supported ?? '未知'}',
    '已创建数量：${status['widgetCount'] ?? '未知'}',
    '结果：${message ?? '尚未请求'}',
  ].join('\n');

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
            '桌面小组件',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            supported == null
                ? '正在检查当前桌面…'
                : supported!
                ? '当前桌面报告支持直接添加'
                : '当前桌面报告不支持直接添加',
          ),
          if (status['device'] != null)
            Text('${status['device']}', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: busy ? null : pin,
            icon: const Icon(Icons.add_to_home_screen),
            label: const Text('添加桌面小组件'),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message!),
            ),
          TextButton(onPressed: manualHelp, child: const Text('手动添加说明')),
          ExpansionTile(
            title: const Text('本机小组件诊断'),
            tilePadding: EdgeInsets.zero,
            children: [
              SelectableText(diagnostic, style: const TextStyle(fontSize: 12)),
              TextButton(
                onPressed: () async {
                  await load();
                  await Clipboard.setData(ClipboardData(text: diagnostic));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制诊断信息，不包含服务器地址或密钥')),
                    );
                  }
                },
                child: const Text('刷新并复制诊断信息'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
