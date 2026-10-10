import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connection.dart';
import 'models.dart';
import 'quota_details.dart';

/// A separate adapter: Keeper uses a same-origin cookie, never the CPA key.
/// Cookies are scoped to this instance and are not logged or persisted.
class KeeperApi {
  KeeperApi(
    this.client, {
    this.pollDelay = const Duration(milliseconds: 500),
    this.pollAttempts = 20,
  });
  final http.Client client;
  final Duration pollDelay;
  final int pollAttempts;
  String? _cookie;
  late Uri _base;

  Future<Json> _request(
    String path, {
    Json? body,
    Map<String, String>? query,
  }) async {
    final uri = _base.replace(
      path: '${_base.path}/api/v1$path',
      queryParameters: query,
    );
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false;
    request.headers.addAll({
      'Accept': 'application/json',
      'Cookie': ?_cookie,
      if (body != null) 'Content-Type': 'application/json',
      if (body != null) 'X-CPA-Usage-Keeper-Request': 'fetch',
    });
    if (body != null) request.body = jsonEncode(body);
    http.Response response;
    try {
      response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const AppError('Keeper 连接超时', retryable: true);
    } on http.ClientException {
      throw const AppError('Keeper 网络连接失败，请检查地址和证书', retryable: true);
    }
    if (response.statusCode == 401) throw const AppError('Keeper 登录已失效或密码错误');
    if (response.statusCode == 403) {
      throw const AppError('Keeper 拒绝访问：查询全部账号额度需要管理员权限');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppError(
        'Keeper 请求失败（HTTP ${response.statusCode}）',
        retryable: response.statusCode == 429 || response.statusCode >= 500,
      );
    }
    if (path == '/auth/login') {
      final cookie = RegExp(
        r'(?:^|,\s*)(cpa_usage_keeper_session=[^;,\s]+)',
      ).firstMatch(response.headers['set-cookie'] ?? '')?.group(1);
      if (cookie == null) throw const AppError('Keeper 未返回登录会话，请检查反向代理');
      _cookie = cookie;
    }
    if (response.bodyBytes.isEmpty) return {};
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is Map) return Json.from(data);
    } on FormatException {
      /* report a sanitized error below */
    }
    throw const AppError('Keeper 返回格式不正确，请检查 /keeper 地址和版本');
  }

  Future<void> _login(ConnectionSettings settings, String password) async {
    _base = settings.baseUri;
    if (_base.scheme != 'https') {
      throw const AppError('Keeper 连接请使用 HTTPS，避免明文发送管理员密码');
    }
    _cookie = null;
    if (password.trim().isEmpty) throw const AppError('请填写 Keeper 管理员密码');
    await _request('/auth/login', body: {'password': password});
  }

  Future<void> _logout() async {
    if (_cookie == null) return;
    try {
      await _request('/auth/logout', body: {});
    } catch (_) {
      /* session expires server-side */
    }
    _cookie = null;
  }

  Future<QuotaSnapshot> refresh(
    ConnectionSettings settings,
    String password,
  ) async {
    await _login(settings, password);
    try {
      final identities = <Json>[];
      for (var page = 1; page <= 1000; page++) {
        final result = await _request(
          '/usage/identities/page',
          query: {'auth_type': '1', 'page': '$page', 'page_size': '100'},
        );
        if (result['identities'] is! List) {
          throw const AppError('Keeper 未返回账号列表');
        }
        identities.addAll(
          (result['identities'] as List).whereType<Map>().map(Json.from),
        );
        if (page >= (number(result['total_pages']) ?? 1)) break;
        if (page == 1000) throw const AppError('Keeper 账号分页超出安全上限');
      }
      final accounts = <AccountQuota>[];
      // Small batches respect the Keeper refresh queue; unknown values stay null.
      for (var start = 0; start < identities.length; start += 4) {
        final batch = identities.skip(start).take(4).toList();
        final ids = batch
            .where((r) => r['disabled'] != true)
            .map((r) => '${r['identity'] ?? ''}')
            .where((id) => id.isNotEmpty)
            .toList();
        final cached = <String, Json>{};
        final latest = <String, Json>{};
        if (ids.isNotEmpty) {
          final cache = await _request(
            '/quota/cache',
            body: {'auth_indexes': ids},
          );
          for (final r in _rows(cache['items'])) {
            cached['${r['auth_index']}'] = r;
          }
          final queued = await _request(
            '/quota/refresh',
            body: {'auth_indexes': ids},
          );
          for (final r in _rows(queued['rejected'])) {
            latest['${r['authIndex']}'] = {'status': 'failed'};
          }
          await Future.wait(
            _rows(queued['tasks']).map((task) async {
              final id = '${task['authIndex'] ?? ''}';
              if (!ids.contains(id)) return;
              try {
                for (var n = 0; n < pollAttempts; n++) {
                  final result = await _request(
                    '/quota/refresh/${Uri.encodeComponent(id)}',
                  );
                  if (result['status'] == 'completed' ||
                      result['status'] == 'failed') {
                    latest[id] = result;
                    return;
                  }
                  await Future<void>.delayed(pollDelay);
                }
              } on AppError catch (error) {
                if (!error.retryable) rethrow;
                latest[id] = {'status': 'failed'};
                return;
              }
              latest[id] = {'status': 'timeout'};
            }),
          );
        }
        for (final identity in batch) {
          final id = '${identity['identity'] ?? ''}';
          final result = latest[id];
          final current = result?['status'] == 'completed';
          final record = current ? result : cached[id];
          accounts.add(
            parseKeeperAccount(
              identity,
              record,
              failure: identity['disabled'] == true
                  ? '已禁用'
                  : current
                  ? null
                  : '本次查询未成功，显示已有缓存；可稍后刷新',
            ),
          );
        }
      }
      return QuotaSnapshot(DateTime.now().toUtc(), accounts);
    } finally {
      await _logout();
    }
  }

  Future<Json> resetOptions(
    ConnectionSettings settings,
    String password,
    String authIndex, {
    required bool claude,
  }) async {
    if (authIndex.isEmpty) throw const AppError('账号标识缺失，请先刷新');
    await _login(settings, password);
    try {
      return await _request(
        '/quota/${claude ? 'claude-reset-grants' : 'reset-credits'}/${Uri.encodeComponent(authIndex)}',
      );
    } finally {
      await _logout();
    }
  }

  /// Mutating, consumable action. Never retry this request automatically.
  Future<Json> resetQuota(
    ConnectionSettings settings,
    String password,
    String authIndex, {
    String? grantId,
    String? organizationId,
  }) async {
    if (authIndex.isEmpty) throw const AppError('账号标识缺失，请先刷新');
    await _login(settings, password);
    try {
      try {
        return await _request(
          '/quota/reset',
          body: {
            'auth_index': authIndex,
            'grant_id': ?grantId,
            'organization_id': ?organizationId,
          },
        );
      } catch (_) {
        // Even an HTTP failure may arrive after upstream has consumed a credit.
        return {'code': 'unknown'};
      }
    } finally {
      await _logout();
    }
  }

  Future<Json> usage(
    ConnectionSettings settings,
    String password,
    int days, {
    String? day,
  }) async {
    await _login(settings, password);
    try {
      if (![1, 7, 30].contains(days)) throw const AppError('不支持的统计范围');
      if (day != null && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
        throw const AppError('日期格式无效');
      }
      final query = day == null
          ? {'range': days == 1 ? 'today' : '${days}d'}
          : {'range': 'custom', 'unit': 'day', 'start': day, 'end': day};
      final overview = await _request('/usage/overview', query: query);
      final analysis = await _request('/usage/analysis', query: query);
      // Do not persist raw analysis payloads (they may contain key identifiers).
      return {'overview': overview, 'analysis': analysis};
    } finally {
      await _logout();
    }
  }
}

List<Json> _rows(dynamic value) =>
    value is List ? value.whereType<Map>().map(Json.from).toList() : [];

AccountQuota parseKeeperAccount(
  Json identity,
  Json? record, {
  String? failure,
}) {
  final data = record?['quota'];
  final rows = data is Map ? _rows(data['quota']) : <Json>[];
  final periods = <QuotaPeriod>[];
  for (final row in rows) {
    final fraction = number(row['remainingFraction']);
    final usedPercent = number(row['usedPercent']);
    double? percent = fraction != null && fraction >= 0 && fraction <= 1
        ? fraction * 100
        : usedPercent != null && usedPercent >= 0
        ? (100 - usedPercent).clamp(0, 100).toDouble()
        : null;
    final metric = '${row['metric'] ?? ''}';
    final divisor = metric == 'usd_cents' ? 100.0 : 1.0;
    final amounts = QuotaAmounts.values(
      total: number(row['limit']) == null
          ? null
          : number(row['limit'])! / divisor,
      used: number(row['used']) == null ? null : number(row['used'])! / divisor,
      remaining: number(row['remaining']) == null
          ? null
          : number(row['remaining'])! / divisor,
    );
    if (percent == null &&
        amounts.total != null &&
        amounts.total! > 0 &&
        amounts.remaining != null) {
      percent = (amounts.remaining! / amounts.total! * 100)
          .clamp(0, 100)
          .toDouble();
    }
    periods.add(
      QuotaPeriod(
        label: '${row['label'] ?? row['key'] ?? '额度窗口'}',
        id: '${row['key'] ?? row['label'] ?? 'window'}:${row['scope'] ?? ''}',
        end: timestamp(row['resetAt']),
        remainingPercent: percent,
        tokens: metric == 'tokens' ? amounts : const QuotaAmounts(),
        usd: metric == 'usd' || metric == 'usd_cents'
            ? amounts
            : const QuotaAmounts(),
      ),
    );
  }
  final primary = rows.indexWhere(
    (r) =>
        r['key'] == 'billing.weekly' ||
        (r['window'] is Map && number(r['window']['seconds']) == 18000),
  );
  final index = primary >= 0
      ? primary
      : periods.indexWhere((p) => p.remainingPercent != null);
  final chosen = index < 0 ? null : periods[index];
  final window = index < 0 ? null : rows[index]['window'];
  return AccountQuota(
    id: '${identity['identity'] ?? identity['id'] ?? ''}',
    provider: providerName('${identity['provider'] ?? identity['type'] ?? ''}'),
    name:
        '${identity['displayName'] ?? identity['name'] ?? identity['id'] ?? '未命名账号'}',
    remaining: chosen?.remainingPercent,
    resetAt: chosen?.end,
    observedAt: timestamp(record?['refreshed_at']),
    queried: record?['status'] == 'completed',
    periods: periods,
    windowMinutes: window is Map
        ? number(window['seconds']) == null
              ? null
              : number(window['seconds'])! / 60
        : null,
    reason:
        failure ??
        (chosen?.remainingPercent == null ? '服务未提供剩余百分比，查看窗口明细' : null),
  );
}
