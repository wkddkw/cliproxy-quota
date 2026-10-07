import 'dart:io';
import 'package:flutter/material.dart';
import 'notification_settings.dart';
import 'help_button.dart';
import 'quota_period_view.dart';
import '../core/quota_details.dart';
import 'package:http/http.dart' as http;
import '../core/connection.dart';
import '../core/models.dart';
import '../core/storage.dart';

class QuotaApp extends StatelessWidget {
  const QuotaApp({super.key, required this.storage});
  final AppStorage storage;
  ThemeData theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff23846b),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xfff5f7f5)
        : const Color(0xff111816),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CLIProxy 限额',
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    home: HomePage(storage: storage),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.storage});
  final AppStorage storage;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final client = http.Client();
  QuotaSnapshot? snapshot;
  bool busy = false;
  bool editing = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    snapshot = widget.storage.snapshot;
    if (widget.storage.settings != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !editing &&
        widget.storage.settings != null &&
        (snapshot == null ||
            DateTime.now().difference(snapshot!.updatedAt).inMinutes >= 1)) {
      refresh();
    }
  }

  Future<void> refresh() async {
    final settings = widget.storage.settings;
    if (busy || settings == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await ManagementApi(
        client,
      ).refresh(settings, await widget.storage.readKey());
      await widget.storage.saveSnapshot(value);
      if (mounted) setState(() => snapshot = value);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is AppError ? e.message : '本地存储或限额缓存更新失败，请重试');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> settings() async {
    editing = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(storage: widget.storage),
      ),
    );
    editing = false;
    if (mounted) {
      setState(() {
        snapshot = widget.storage.snapshot;
        error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.storage.settings == null) {
      return SettingsPage(
        storage: widget.storage,
        onSaved: () => setState(() {
          snapshot = widget.storage.snapshot;
          error = null;
        }),
      );
    }
    final providers = snapshot?.providers ?? [];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          snapshot == null ? '尚未刷新' : '更新于 ${formatTime(snapshot!.updatedAt)}',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            onPressed: busy ? null : settings,
            tooltip: '设置',
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          children: [
            const Text(
              '剩余，心中有数。',
              style: TextStyle(fontSize: 29, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text('按供应商查看 · 多账号取最低剩余'),
            const SizedBox(height: 28),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 20),
                child: LinearProgressIndicator(),
              ),
            if (error != null) Notice('$error\n保留上次成功刷新结果。'),
            if (!busy && providers.isEmpty) const Notice('还没有认证文件，下拉刷新查看。'),
            for (final provider in providers)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: ProviderCard(
                  provider: provider,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AccountsPage(provider: provider),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.storage, this.onSaved});
  final AppStorage storage;
  final VoidCallback? onSaved;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final server = TextEditingController(), key = TextEditingController();
  final port = TextEditingController(text: '8317'),
      address = TextEditingController();
  bool hide = true, busy = false, loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    final saved = widget.storage.settings;
    server.text = saved?.server ?? '';
    port.text = '${saved?.port ?? 8317}';
    address.text = saved?.fullAddress ?? '';
    loadKey();
  }

  Future<void> loadKey() async {
    try {
      final value = await widget.storage.readKey();
      if (mounted) key.text = value;
    } catch (_) {
      if (mounted) setState(() => error = '无法读取系统安全存储，请重新输入管理密钥');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    server.dispose();
    key.dispose();
    port.dispose();
    address.dispose();
    super.dispose();
  }

  void finish() {
    if (widget.onSaved != null) {
      widget.onSaved!();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    final client = http.Client();
    try {
      final value = ConnectionSettings(
        server: server.text.trim(),
        port: int.tryParse(port.text.trim()) ?? 0,
        fullAddress: address.text.trim(),
      );
      final snapshot = await ManagementApi(client).refresh(value, key.text);
      await widget.storage.saveConnection(value, key.text);
      await widget.storage.saveSnapshot(snapshot);
      if (mounted) finish();
    } catch (e) {
      if (mounted) {
        setState(() => error = e is AppError ? e.message : '保存失败，请检查系统安全存储并重试');
      }
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除这台服务器？'),
        content: const Text('移除本机保存的地址、密钥与缓存，并关闭通知监测。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.storage.clear();
      if (mounted) finish();
    } catch (_) {
      if (mounted) setState(() => error = '清除失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('连接服务器'),
        actions: const [
          HelpButton(
            title: '连接服务器',
            text:
                '服务器填写 IP 或主机名。管理密钥是 secret-key 或 MANAGEMENT_PASSWORD，保存在本机系统安全存储。\n\n默认端口为 8317；完整地址填写后优先使用。建议通过 Tailscale 或家庭 VPN 连接。',
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(28),
            children: [
              TextField(
                controller: server,
                enabled: !busy && !loading,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '服务器',
                  hintText: '100.64.0.10 或 proxy.home',
                ),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: key,
                enabled: !busy && !loading,
                obscureText: hide,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '管理密钥',
                  suffixIcon: IconButton(
                    tooltip: hide ? '显示密钥' : '隐藏密钥',
                    onPressed: () => setState(() => hide = !hide),
                    icon: Icon(
                      hide
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (error != null) Notice(error!),
              FilledButton(
                onPressed: busy || loading ? null : save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(18),
                ),
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存并连接'),
              ),
              const SizedBox(height: 20),
              ExpansionTile(
                title: const Text('更多'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.symmetric(vertical: 12),
                children: [
                  TextField(
                    controller: port,
                    enabled: !busy && !loading,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口'),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: address,
                    enabled: !busy && !loading,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '完整地址（可选）',
                      hintText: 'https://cpa.example.com',
                    ),
                  ),
                  if (widget.storage.settings != null)
                    TextButton.icon(
                      onPressed: busy || loading ? null : clear,
                      icon: const Icon(Icons.link_off),
                      label: const Text('清除这台服务器'),
                    ),
                ],
              ),
              if (Platform.isAndroid)
                NotificationSettingsPanel(storage: widget.storage),
            ],
          ),
        ),
      ),
    ),
  );
}

class ProviderCard extends StatelessWidget {
  const ProviderCard({super.key, required this.provider, required this.onTap});
  final ProviderQuota provider;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final value = provider.remaining;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 23,
                    child: switch (provider.name) {
                      'GPT' || 'Claude' || 'Grok' => Image.asset(
                        'assets/providers/${provider.name.toLowerCase()}.png',
                        width: 28,
                        height: 28,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      _ => Text(
                        provider.symbol,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    },
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          provider.name,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${provider.accounts.length} 个账号',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    value == null ? '—' : '${value.floor()}%',
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: value == null ? 0 : value / 100,
                  minHeight: 7,
                  color: value != null && value <= 15
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
              if (!provider.supported || provider.issues > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      !provider.supported
                          ? '暂不支持'
                          : '${provider.issues} 个账号需要查看 · 点开了解原因',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key, required this.provider});
  final ProviderQuota provider;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(provider.name)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('${provider.accounts.length} 个认证文件'),
        const SizedBox(height: 16),
        for (final account in provider.accounts)
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (account.reason != null)
                    Text(
                      account.reason!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (account.remaining != null)
                    Text(
                      '剩余 ${account.remaining!.floor()}%',
                      style: const TextStyle(fontSize: 24),
                    ),
                  const SizedBox(height: 8),
                  if (account.periods.isEmpty &&
                      (account.windowMinutes ?? 0) > 0)
                    Text(windowLabel(account.windowMinutes)),
                  if (account.periods.isEmpty && account.resetAt != null)
                    Text('重置于 ${formatTime(account.resetAt!)}'),
                  if (account.observedAt != null)
                    Text(
                      '${account.queried ? '额度查询于' : '服务器记录于'} ${formatTime(account.observedAt!)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  for (final period in account.periods)
                    QuotaPeriodView(
                      period: period,
                      showPercent:
                          account.periods.length > 1 ||
                          period.remainingPercent != account.remaining,
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.error, height: 1.6),
    ),
  );
}

String formatTime(DateTime value) {
  final local = value.toLocal();
  String pad(int v) => '$v'.padLeft(2, '0');
  return '${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
}
