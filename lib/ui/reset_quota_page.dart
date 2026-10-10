import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/connection.dart';
import '../core/keeper.dart';
import '../core/models.dart';
import '../core/storage.dart';

class ResetQuotaPage extends StatefulWidget {
  const ResetQuotaPage({
    super.key,
    required this.storage,
    required this.account,
    this.client,
  });
  final AppStorage storage;
  final AccountQuota account;
  final http.Client? client;
  @override
  State<ResetQuotaPage> createState() => _ResetQuotaPageState();
}

class _ResetQuotaPageState extends State<ResetQuotaPage> {
  late final http.Client client;
  late final ConnectionSettings settings;
  late final String epoch;
  Json? options;
  String? error, result;
  bool busy = false, attempted = false;
  bool get claude => widget.account.provider == 'Claude';
  String? selected;
  List<Json> get grants {
    final value = options?['status'] is Map
        ? options!['status']['grants']
        : options?['credits'];
    return value is List ? value.whereType<Map>().map(Json.from).toList() : [];
  }

  int? get count {
    final value = claude
        ? (options?['status'] is Map
              ? options!['status']['availableCount']
              : null)
        : options?['availableCount'];
    return value is num && value >= 0 ? value.toInt() : null;
  }

  @override
  void initState() {
    super.initState();
    client = widget.client ?? http.Client();
    settings = widget.storage.settings!;
    epoch = widget.storage.connectionEpoch;
    load();
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
      options = null;
    });
    try {
      final value = await KeeperApi(client).resetOptions(
        settings,
        await widget.storage.readKey(),
        widget.account.id ?? '',
        claude: claude,
      );
      if (mounted) {
        setState(() {
          options = value;
          selected = value['selectedGrantId'] as String?;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is AppError ? e.message : '无法读取重置权益');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool get canReset =>
      !busy &&
      !attempted &&
      (count ?? 0) > 0 &&
      (!claude ||
          (options?['status'] is Map &&
              options!['status']['eligible'] == true &&
              selected != null &&
              '${options?['organizationId'] ?? ''}'.isNotEmpty &&
              grants.any(
                (g) =>
                    g['id'] == selected &&
                    g['usableNow'] == true &&
                    g['paused'] != true &&
                    (g['resetsLeft'] as num? ?? 0) > 0,
              )));
  Future<void> reset() async {
    if (!canReset) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认使用一次重置权益？'),
        content: Text(
          '账号：${widget.account.name}\n这会真实消耗官方重置卡或权益，无法撤回。不是刷新显示，也不是清空统计。\n${claude ? '权益：$selected' : '由官方选择可用重置卡'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('使用一次并重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !canReset) return;
    if (widget.storage.connectionEpoch != epoch) {
      setState(() => error = '连接已变化，请返回重新打开');
      return;
    }
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    try {
      final password = await widget.storage.readKey();
      final response = await KeeperApi(client).resetQuota(
        settings,
        password,
        widget.account.id ?? '',
        grantId: claude ? selected : null,
        organizationId: claude ? (options?['organizationId'] as String?) : null,
      );
      final code = '${response['code'] ?? ''}';
      final successful =
          code == 'reset' ||
          code == 'success' ||
          (response['windowsReset'] as num? ?? 0) > 0;
      const messages = {
        'already_used': '该权益已使用，请勿重复提交',
        'not_limited': '当前未达到限制，无需重置',
        'cooldown': '仍在冷却期',
        'ineligible': '当前账号不符合重置条件',
        'unavailable': '当前没有可用重置权益',
        'rate_limited': '请求被限流，请先核对额度与权益',
        'auth_error': '上游认证失败，请检查账号',
      };
      if (mounted) {
        setState(
          () => result = successful
              ? '官方重置成功${response['recoveryFailed'] == true ? '，但 CLIProxy 路由恢复失败，请在管理端检查，不要再次消耗重置卡' : ''}'
              : messages[code] ?? '重置结果不确定，可能已消耗次数。请核对额度与权益，不要重复提交。',
        );
      }
      // Read-only refresh follows a single explicit mutation, never a retry.
      final snapshot = await KeeperApi(client).refresh(settings, password);
      if (widget.storage.connectionEpoch == epoch) {
        await widget.storage.saveSnapshot(snapshot);
      }
      final account = snapshot.accounts
          .where((a) => a.id == widget.account.id)
          .firstOrNull;
      if (mounted) {
        setState(
          () => result =
              '$result\n${account?.reason == null ? '已重新查询额度' : '刷新未成功，保留缓存'}：${account?.remaining == null ? '未知' : '${account!.remaining!.floor()}%'}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              '${result == null ? '操作结果未确认，请勿重复提交。' : '额度刷新未成功。'} ${e is AppError ? e.message : '请稍后核对'}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('重置额度')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            widget.account.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          const Text('仅手动确认后消耗官方重置权益。定时刷新不会执行重置。'),
          if (busy) const LinearProgressIndicator(),
          if (options != null) Text('可用次数：${count ?? '未知'}'),
          for (final grant in grants)
            Card(
              child: ListTile(
                title: Text('${grant['label'] ?? grant['id'] ?? '重置卡'}'),
                subtitle: Text(
                  '有效期至：${grant['endsAt'] ?? grant['expiresAt'] ?? '未提供'}${claude ? '\n剩余 ${grant['resetsLeft'] ?? '未知'} 次；重置范围：${(grant['clears'] as List? ?? []).join('、')}' : '\n状态：${grant['status'] ?? '未知'}'}',
                ),
                trailing: claude
                    ? IconButton(
                        tooltip: '选择权益',
                        icon: Icon(
                          selected == grant['id']
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        onPressed: busy || attempted
                            ? null
                            : () => setState(() => selected = '${grant['id']}'),
                      )
                    : null,
              ),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (result != null) Text(result!),
          if (attempted) const Text('本次操作已提交，不提供自动重试。可重新查询确认权益和额度变化。'),
          TextButton(
            onPressed: busy ? null : load,
            child: const Text('重新查询重置权益'),
          ),
          FilledButton(
            onPressed: canReset ? reset : null,
            child: const Text('使用重置权益'),
          ),
        ],
      ),
    ),
  );
}
