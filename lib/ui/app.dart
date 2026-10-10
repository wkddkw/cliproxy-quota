import 'dart:io';

import 'package:flutter/material.dart';

import 'notification_settings.dart';
import 'help_button.dart';
import 'update_settings.dart';
import 'quota_period_view.dart';
import 'usage_page.dart';
import '../core/quota_details.dart';
import 'reset_quota_page.dart';

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
        ? const Color(0xfffaf9f5)
        : const Color(0xff201e1b),
    cardTheme: CardThemeData(
      color: brightness == Brightness.light
          ? const Color(0xfff0eee8)
          : const Color(0xff2d2a26),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
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
  int tab = 0;
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
    if (state == AppLifecycleState.resumed) reloadSnapshot();
    if (state == AppLifecycleState.resumed &&
        !editing &&
        widget.storage.settings != null &&
        (snapshot == null ||
            DateTime.now().difference(snapshot!.updatedAt).inMinutes >= 1)) {
      refresh();
    }
  }

  Future<void> reloadSnapshot() async {
    await widget.storage.preferences.reload();
    if (mounted) setState(() => snapshot = widget.storage.snapshot);
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
        tab = 0;
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
    if (tab == 1) {
      return UsagePage(storage: widget.storage, navigation: navigation());
    }
    final providers = snapshot?.providers ?? [];
    return Scaffold(
      bottomNavigationBar: navigation(),
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
            const Text('有效账号最低剩余 · 异常账号独立显示'),
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
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AccountsPage(
                          provider: provider,
                          storage: widget.storage,
                        ),
                      ),
                    );
                    await reloadSnapshot();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget navigation() => NavigationBar(
    selectedIndex: tab,
    onDestinationSelected: (value) async {
      if (busy) return;
      if (value == 2) {
        await settings();
        return;
      }
      setState(() => tab = value);
    },
    destinations: const [
      NavigationDestination(icon: Icon(Icons.donut_large_rounded), label: '额度'),
      NavigationDestination(icon: Icon(Icons.bar_chart_rounded), label: '用量'),
      NavigationDestination(icon: Icon(Icons.tune_rounded), label: '设置'),
    ],
  );
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
  final keeperKey = TextEditingController(),
      keeperAddress = TextEditingController(),
      cpaAddress = TextEditingController();
  final port = TextEditingController(text: '8443');
  String backend = 'keeper', scheme = 'https';
  bool hide = true, busy = false, loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    final saved = widget.storage.settings;
    backend = saved?.backend ?? 'keeper';
    if (saved != null) {
      final origin = saved.unified ? saved.sharedOrigin : saved.baseUri;
      server.text = origin.host;
      port.text = '${origin.port}';
      scheme = origin.scheme;
      keeperAddress.text = saved.unified
          ? saved.keeperAddress
          : saved.isKeeper && origin.path != '/keeper'
          ? origin.toString()
          : '';
      cpaAddress.text = saved.unified ? saved.cpaAddress : '';
    }
    loadKey();
  }

  Future<void> loadKey() async {
    try {
      final cpa = await widget.storage.readBackendKey('cpa');
      final keeper = await widget.storage.readBackendKey('keeper');
      if (mounted) {
        key.text = cpa;
        keeperKey.text = keeper;
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法读取系统安全存储，请重新输入登录信息');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    for (final c in [server, key, keeperKey, keeperAddress, cpaAddress, port]) {
      c.dispose();
    }
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
        backend: backend,
        unified: true,
        scheme: scheme,
        keeperAddress: keeperAddress.text.trim(),
        cpaAddress: cpaAddress.text.trim(),
      );
      final credential = backend == 'keeper' ? keeperKey.text : key.text;
      final snapshot = await ManagementApi(client).refresh(value, credential);
      await widget.storage.saveConnection(
        value,
        credential,
        cpaKey: key.text,
        keeperKey: keeperKey.text,
      );
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
        actions: [
          HelpButton(
            title: '连接服务器',
            text:
                '默认共用一个服务器 IP、端口和协议，CLIProxy 使用根地址，Keeper 自动使用 /keeper。也可直接粘贴管理页面或 Keeper 页面网址。分开部署时在高级设置覆盖地址。两边凭据独立保存，不自动互用。开启 Keeper 后额度、统计与重置使用 Keeper；关闭后额度直接查询 CLIProxy。',
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
                  hintText: 'IP、域名或完整页面地址',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: scheme,
                      decoration: const InputDecoration(labelText: '协议'),
                      items: const [
                        DropdownMenuItem(value: 'https', child: Text('HTTPS')),
                        DropdownMenuItem(value: 'http', child: Text('HTTP')),
                      ],
                      onChanged: busy || loading
                          ? null
                          : (v) => setState(() => scheme = v!),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: port,
                      enabled: !busy && !loading,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '端口'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 Keeper 额度与统计'),
                subtitle: const Text('默认使用同一服务器的 /keeper'),
                value: backend == 'keeper',
                onChanged: busy || loading
                    ? null
                    : (v) => setState(() => backend = v ? 'keeper' : 'cpa'),
              ),
              TextField(
                controller: key,
                enabled: !busy && !loading,
                obscureText: hide,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'CLIProxy 管理密钥',
                  helperText: '直接连接 CLIProxy 时使用；仅使用 Keeper 可留空',
                ),
              ),
              const SizedBox(height: 16),
              if (backend == 'keeper')
                TextField(
                  controller: keeperKey,
                  enabled: !busy && !loading,
                  obscureText: hide,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Keeper 管理员密码'),
                ),
              TextButton(
                onPressed: () => setState(() => hide = !hide),
                child: Text(hide ? '显示登录信息' : '隐藏登录信息'),
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
                title: const Text('高级设置：独立部署地址'),
                tilePadding: EdgeInsets.zero,
                children: [
                  TextField(
                    controller: keeperAddress,
                    enabled: !busy && !loading,
                    decoration: const InputDecoration(
                      labelText: 'Keeper 独立地址（可选）',
                      hintText: 'https://other.example/keeper',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: cpaAddress,
                    enabled: !busy && !loading,
                    decoration: const InputDecoration(
                      labelText: 'CLIProxy 独立地址（可选）',
                      hintText: 'https://proxy.example',
                    ),
                  ),
                ],
              ),
              if (widget.storage.settings != null)
                TextButton.icon(
                  onPressed: busy || loading ? null : clear,
                  icon: const Icon(Icons.link_off),
                  label: const Text('清除这台服务器'),
                ),
              if (Platform.isAndroid)
                NotificationSettingsPanel(storage: widget.storage),
              if (Platform.isAndroid) const UpdateSettingsPanel(),
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
                          '${provider.availableCount}/${provider.accounts.length} 个账号可用',
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

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.provider, this.storage});
  final AppStorage? storage;
  final ProviderQuota provider;
  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  AppStorage? get storage => widget.storage;
  ProviderQuota get provider =>
      storage?.snapshot?.providers
          .where((p) => p.name == widget.provider.name)
          .firstOrNull ??
      widget.provider;
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
                  if (storage?.settings?.isKeeper == true &&
                      ['GPT', 'Claude'].contains(account.provider) &&
                      (account.id ?? '').isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ResetQuotaPage(
                              storage: storage!,
                              account: account,
                            ),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('查看重置卡 / 重置额度'),
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
