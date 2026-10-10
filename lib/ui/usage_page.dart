import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/connection.dart';
import '../core/keeper.dart';
import '../core/models.dart';
import '../core/storage.dart';

class UsagePage extends StatefulWidget {
  const UsagePage({
    super.key,
    required this.storage,
    required this.navigation,
    this.client,
  });
  final AppStorage storage;
  final Widget navigation;
  final http.Client? client;
  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  late final http.Client client;
  int days = 1, generation = 0;
  String dimension = 'model_composition';
  Json? data;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    client = widget.client ?? http.Client();
    load();
  }

  @override
  void dispose() {
    client.close();
    super.dispose();
  }

  Future<void> load() async {
    final settings = widget.storage.settings;
    if (settings == null || !settings.isKeeper) return;
    final current = ++generation;
    setState(() {
      busy = true;
      error = null;
      data = null;
    });
    try {
      final result = await KeeperApi(
        client,
      ).usage(settings, await widget.storage.readKey(), days);
      if (mounted && generation == current) setState(() => data = result);
    } catch (e) {
      if (mounted && generation == current) {
        setState(() => error = e is AppError ? e.message : '用量获取失败，请重试');
      }
    } finally {
      if (mounted && generation == current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = data?['overview'];
    final usage = overview is Map && overview['usage'] is Map
        ? overview['usage'] as Map
        : {};
    final summary = overview is Map && overview['summary'] is Map
        ? overview['summary'] as Map
        : {};
    final analysis = data?['analysis'];
    final rows = analysis is Map && analysis[dimension] is List
        ? (analysis[dimension] as List).whereType<Map>().toList()
        : <Map>[];
    return Scaffold(
      appBar: AppBar(title: const Text('用量')),
      bottomNavigationBar: widget.navigation,
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '消耗，一目了然。',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text('额度与用量分开统计。费用按模型价格估算，不代表实际账单。'),
            const SizedBox(height: 24),
            if (widget.storage.settings?.isKeeper != true)
              const Text('连接 Keeper 后可查看用户、账号及模型用量。'),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('今天')),
                ButtonSegment(value: 7, label: Text('7 天')),
                ButtonSegment(value: 30, label: Text('30 天')),
              ],
              selected: {days},
              onSelectionChanged: (v) {
                setState(() => days = v.first);
                load();
              },
            ),
            const SizedBox(height: 20),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(error!),
              ),
            if (data != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${usage['total_requests'] ?? '—'} 次请求',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text('${usage['total_tokens'] ?? '—'} Tokens'),
                      Text(
                        summary['cost_available'] == true &&
                                number(summary['total_cost']) != null
                            ? '估算费用 \$${number(summary['total_cost'])!.toStringAsFixed(3)}'
                            : '费用数据不可用',
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: dimension,
              decoration: const InputDecoration(labelText: '统计维度'),
              items: const [
                DropdownMenuItem(
                  value: 'api_key_composition',
                  child: Text('用户 / API Key'),
                ),
                DropdownMenuItem(
                  value: 'auth_files_composition',
                  child: Text('上游账号'),
                ),
                DropdownMenuItem(value: 'model_composition', child: Text('模型')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => dimension = v);
              },
            ),
            if (dimension == 'api_key_composition')
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('按分发的 Key 区分用户；多人共用 Key 时无法区分个人。'),
              ),
            if (!busy && data != null && rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('该时间范围没有用量记录'),
              ),
            for (var i = 0; i < rows.length; i++)
              Card(
                child: ListTile(
                  title: Text(
                    '${rows[i]['label'] ?? (dimension == 'model_composition' ? rows[i]['key'] : null) ?? '账号 ${i + 1}'}',
                  ),
                  subtitle: Text(
                    '${rows[i]['requests'] ?? '—'} 次 · ${rows[i]['total_tokens'] ?? '—'} Tokens',
                  ),
                  trailing: Text(
                    rows[i]['cost_available'] == true &&
                            number(rows[i]['cost_usd']) != null
                        ? '\$${number(rows[i]['cost_usd'])!.toStringAsFixed(3)}'
                        : '—',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
