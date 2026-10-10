import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/connection.dart';
import '../core/keeper.dart';
import '../core/models.dart';
import '../core/storage.dart';
import '../core/usage_format.dart';

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
  String? selectedDay;
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
      ).usage(settings, await widget.storage.readKey(), days, day: selectedDay);
      if (mounted && generation == current) setState(() => data = result);
    } catch (e) {
      if (mounted && generation == current) {
        setState(() => error = e is AppError ? e.message : '用量获取失败，请重试');
      }
    } finally {
      if (mounted && generation == current) setState(() => busy = false);
    }
  }

  void details(String title, Map row) {
    const labels = {
      'total_tokens': '总 Token',
      'requests': '请求次数',
      'input_tokens': '输入 Token',
      'output_tokens': '输出 Token',
      'cache_read_tokens': '缓存读取',
      'cache_creation_tokens': '缓存写入',
      'reasoning_tokens': '推理 Token',
    };
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in labels.entries)
                SelectableText('${e.value}：${exactUsage(row[e.key])}'),
              const SizedBox(height: 12),
              Text(
                '估算费用：${usageCost(row, field: row.containsKey('total_cost') ? 'total_cost' : 'cost_usd')}',
              ),
              const Text(
                'K=千，M=百万，B=十亿。Token 子项按服务端口径展示，可能重叠，不再相加。“部分”表示已有估算金额不完整，请检查 Keeper 模型价格配置；不能当作完整账单或 0 元。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
    final rows = dimension == 'daily'
        ? dailyUsage(analysis is Map ? analysis['token_usage'] : null)
        : analysis is Map && analysis[dimension] is List
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
                setState(() {
                  days = v.first;
                  selectedDay = null;
                });
                load();
              },
            ),
            if (selectedDay != null)
              InputChip(
                label: Text('$selectedDay · 每人用量'),
                onDeleted: () {
                  setState(() => selectedDay = null);
                  load();
                },
              ),
            if (analysis is Map && analysis['timezone'] != null)
              Text('统计时区：${analysis['timezone']}'),
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
                        '${compactUsage(usage['total_requests'])} 次请求',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '${compactUsage(usage['total_tokens'])} Tokens',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(
                        '缓存读取：${compactUsage(summary['cache_read_tokens'])} · 缓存写入：${compactUsage(summary['cache_creation_tokens'])}\n推理：${compactUsage(summary['reasoning_tokens'])}',
                      ),
                      TextButton(
                        onPressed: () => details('总用量', {...summary, ...usage}),
                        child: const Text('精确数值与说明'),
                      ),
                      Text('估算费用 ${usageCost(summary, field: 'total_cost')}'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: dimension,
              decoration: const InputDecoration(labelText: '统计维度'),
              items: const [
                DropdownMenuItem(value: 'daily', child: Text('每天')),
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
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${rows[i]['label'] ?? (dimension == 'model_composition' ? rows[i]['key'] : null) ?? '账号 ${i + 1}'}',
                        ),
                        subtitle: Text(
                          '${compactUsage(rows[i]['requests'])} 次 · ${compactUsage(rows[i]['total_tokens'])} Tokens',
                        ),
                        trailing: Text(usageCost(rows[i])),
                        onTap: () =>
                            details('${rows[i]['label'] ?? '用量详情'}', rows[i]),
                      ),
                      Text(
                        '缓存读取：${compactUsage(rows[i]['cache_read_tokens'])} · 缓存写入：${compactUsage(rows[i]['cache_creation_tokens'])}\n推理：${compactUsage(rows[i]['reasoning_tokens'])}',
                      ),
                      if (dimension == 'daily')
                        TextButton(
                          onPressed: () {
                            setState(() {
                              selectedDay = '${rows[i]['day']}';
                              dimension = 'api_key_composition';
                            });
                            load();
                          },
                          child: const Text('查看当天每人用量'),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
