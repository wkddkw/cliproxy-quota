import 'package:flutter/material.dart';
import '../core/storage.dart';

class WidgetSetupPanel extends StatefulWidget {
  const WidgetSetupPanel({super.key});
  @override
  State<WidgetSetupPanel> createState() => _WidgetSetupPanelState();
}

class _WidgetSetupPanelState extends State<WidgetSetupPanel> {
  bool? supported;
  String? device;
  String? message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final status = await AppStorage.channel.invokeMapMethod<String, dynamic>(
        'widgetStatus',
      );
      if (mounted) {
        setState(() {
          supported = status?['pinSupported'] == true;
          device = status?['device'];
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = '无法检查当前桌面，可尝试系统的小组件菜单');
    }
  }

  Future<void> pin() async {
    setState(() => busy = true);
    try {
      final requested =
          await AppStorage.channel.invokeMethod<bool>('pinWidget') == true;
      if (mounted) {
        setState(
          () => message = requested
              ? '已请求系统确认，请在桌面弹窗中点击添加。'
              : '当前桌面未接受添加请求，请在桌面编辑菜单中查找 Android 小组件。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => message = '添加请求失败，请尝试系统的小组件菜单');
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
            '桌面小组件',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            supported == null
                ? '正在检查当前桌面…'
                : supported!
                ? '当前桌面支持直接添加'
                : '当前桌面不支持直接添加，可尝试手动添加',
          ),
          if (device != null)
            Text(device!, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: supported == true && !busy ? pin : null,
            icon: const Icon(Icons.add_to_home_screen),
            label: const Text('添加桌面小组件'),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message!),
            ),
          const SizedBox(height: 8),
          const Text(
            '厂商卡片中心与 Android 小组件入口可能不同。长按桌面空白处，在桌面编辑菜单中查找“小组件”或“Android 小组件”。是否能直接添加取决于当前桌面，不能仅按手机品牌判断。',
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
        ],
      ),
    ),
  );
}
