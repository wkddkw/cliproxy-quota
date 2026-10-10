import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'live_quota.dart';
import 'keeper.dart';

class ConnectionSettings {
  const ConnectionSettings({
    required this.server,
    this.port = 8317,
    this.fullAddress = '',
    this.backend = 'cpa',
  });
  final String server;
  final int port;
  final String fullAddress;
  final String backend;
  bool get isKeeper => backend == 'keeper';
  Uri get baseUri {
    if (port < 1 || port > 65535) throw const AppError('端口须在 1–65535 之间');
    if (fullAddress.trim().isNotEmpty) {
      final parsed = Uri.tryParse(fullAddress.trim());
      if (parsed == null ||
          !['http', 'https'].contains(parsed.scheme) ||
          parsed.host.isEmpty ||
          parsed.userInfo.isNotEmpty ||
          parsed.hasQuery ||
          parsed.hasFragment) {
        throw const AppError('完整地址须为 http:// 或 https:// 地址，不能包含账号、查询参数');
      }
      final path = parsed.path
          .replaceFirst(
            RegExp(r'/(v8/management|v0/management|management\.html)/?$'),
            '',
          )
          .replaceFirst(RegExp(r'/+$'), '');
      if (!isKeeper && path.isNotEmpty) {
        throw const AppError('完整地址只能包含主机、端口及管理页面后缀');
      }
      return parsed.replace(path: isKeeper ? path : '');
    }
    var host = server.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty ||
        host.contains(RegExp(r'[/\s?#@]')) ||
        (host.contains(':') &&
            InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6)) {
      throw const AppError('服务器只填 IP 或主机名；端口和完整地址请在「更多」中填写');
    }
    return Uri(scheme: 'http', host: host, port: port);
  }

  Json toJson() => {
    'server': server,
    'port': port,
    'fullAddress': fullAddress,
    'backend': backend,
  };
  factory ConnectionSettings.fromJson(Json json) => ConnectionSettings(
    server: json['server'] as String,
    port: json['port'] as int,
    fullAddress: json['fullAddress'] as String,
    backend: json['backend'] == 'keeper' ? 'keeper' : 'cpa',
  );
}

class AppError implements Exception {
  const AppError(this.message, {this.retryable = false});
  final bool retryable;
  final String message;
  @override
  String toString() => message;
}

class ManagementApi {
  ManagementApi(this.client);
  final http.Client client;
  Future<QuotaSnapshot> refresh(ConnectionSettings settings, String key) async {
    if (settings.isKeeper) return KeeperApi(client).refresh(settings, key);
    if (key.trim().isEmpty) throw const AppError('请填写管理密钥，不是客户端 api-keys');
    final base = settings.baseUri;
    try {
      // The bare management roots are not registered routes upstream. Probe the
      // read-only credentials resource instead; only 404 permits a v0 fallback.
      var response = await _get(
        base.replace(path: '/v8/management/credentials'),
        key,
      );
      var prefix = '/v8/management';
      if (response.statusCode == 404) {
        prefix = '/v0/management';
        response = await _get(
          base.replace(path: '/v0/management/auth-files'),
          key,
        );
      }
      if (response.statusCode == 401) {
        throw const AppError('管理密钥错误或已失效，请检查 secret-key / MANAGEMENT_PASSWORD');
      }
      if (response.statusCode == 403) {
        throw const AppError('服务拒绝访问，请检查是否允许远程管理或是否触发访问限制');
      }
      if (response.statusCode == 404) {
        throw const AppError('没有找到管理接口，请到「更多」检查端口或完整地址');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const AppError('管理接口返回重定向，请在「更多」填写最终地址');
      }
      if (response.statusCode != 200) {
        throw AppError(
          '服务请求失败（HTTP ${response.statusCode}），可稍后重试',
          retryable: response.statusCode == 429 || response.statusCode >= 500,
        );
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map ||
          data['files'] is! List ||
          (data['files'] as List).any((f) => f is! Map)) {
        throw const AppError('接口返回格式不正确：未找到认证文件列表');
      }
      final files = (data['files'] as List).map((f) => Json.from(f)).toList();
      final accounts = files.map(AccountQuota.fromApi).toList();
      final plugins = await _plugins(base, prefix, key);
      // Bound concurrent probes. Requests stay on the user's CLIProxy host.
      for (var start = 0; start < files.length; start += 4) {
        final end = (start + 4).clamp(0, files.length);
        await Future.wait(
          List.generate(end - start, (offset) async {
            final index = start + offset;
            final file = files[index];
            if (file['disabled'] == true || file['status'] == 'disabled') {
              return;
            }
            final rawProvider = '${file['provider'] ?? file['type'] ?? ''}'
                .toLowerCase();
            final plugin = plugins
                .where(
                  (p) => '${p['quota_provider']}'.toLowerCase() == rawProvider,
                )
                .firstOrNull;
            final builtin = rawProvider == 'codex' || rawProvider == 'claude';
            if (!builtin &&
                accounts[index].provider != 'Grok' &&
                (file['unavailable'] == true || file['status'] == 'error')) {
              return;
            }
            if ('${file['auth_index'] ?? file['authIndex'] ?? ''}'.isEmpty) {
              if (builtin) {
                accounts[index] = accounts[index].withQueryFailure(
                  '无法主动查询 · 缺少认证查询索引',
                );
              }
              return;
            }
            if (builtin) {
              accounts[index] = await _oauthQuota(
                base,
                prefix,
                key,
                file,
                accounts[index],
                rawProvider,
              );
              return;
            }
            if (plugin == null) {
              if (accounts[index].provider == 'Grok') {
                accounts[index] = await _grokQuota(
                  base,
                  prefix,
                  key,
                  file,
                  accounts[index],
                );
              }
              return;
            }
            final uri = base.replace(
              path:
                  '$prefix/plugins/${Uri.encodeComponent('${plugin['id']}')}/quota',
              queryParameters: {'auth_index': '${file['auth_index']}'},
            );
            try {
              final result = await _get(uri, key);
              if (result.statusCode == 200) {
                final normalized = jsonDecode(utf8.decode(result.bodyBytes));
                accounts[index] = accounts[index].withProbe(
                  data: normalized is Map ? Json.from(normalized) : null,
                  failure: normalized is Map ? null : '探测失败 · 返回格式不正确',
                );
              } else if (accounts[index].remaining == null) {
                accounts[index] = accounts[index].withProbe(
                  available:
                      result.statusCode != 404 && result.statusCode != 501,
                  failure: result.statusCode == 404 || result.statusCode == 501
                      ? '暂不支持'
                      : '探测失败（HTTP ${result.statusCode}）',
                );
              }
            } catch (_) {
              if (accounts[index].remaining == null) {
                accounts[index] = accounts[index].withProbe(
                  failure: '探测失败 · 网络或返回格式异常',
                );
              }
            }
            if (accounts[index].provider == 'Grok' &&
                accounts[index].remaining == null) {
              accounts[index] = await _grokQuota(
                base,
                prefix,
                key,
                file,
                accounts[index],
              );
            }
          }),
        );
      }
      return QuotaSnapshot(DateTime.now().toUtc(), accounts);
    } on AppError {
      rethrow;
    } on TimeoutException {
      throw const AppError('连接超时，请检查服务器和 VPN / Tailscale', retryable: true);
    } on SocketException {
      throw const AppError('无法连接服务器，请检查网络、VPN 和「更多」中的地址', retryable: true);
    } on http.ClientException {
      throw const AppError('网络连接失败，请检查服务器地址及 HTTPS 证书', retryable: true);
    } on FormatException {
      throw const AppError('接口返回的不是有效 JSON，请检查完整地址');
    }
  }

  Future<AccountQuota> _oauthQuota(
    Uri base,
    String prefix,
    String key,
    Json file,
    AccountQuota account,
    String provider,
  ) async {
    final codex = provider == 'codex';
    final header = <String, String>{
      'Authorization': 'Bearer \$TOKEN\$',
      'Content-Type': 'application/json',
      'User-Agent': codex
          ? 'codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)'
          : 'claude-cli/2.1.280 (external, cli)',
      if (!codex) 'anthropic-beta': 'oauth-2025-04-20',
    };
    if (codex) {
      for (final row in [
        file,
        file['id_token'],
        file['metadata'],
        file['attributes'],
      ]) {
        if (row is! Map) continue;
        final claims = row['https://api.openai.com/auth'];
        final id =
            row['chatgpt_account_id'] ??
            row['account_id'] ??
            (claims is Map ? claims['chatgpt_account_id'] : null);
        if (id != null && '$id'.trim().isNotEmpty) {
          header['Chatgpt-Account-Id'] = '$id';
          break;
        }
      }
    }
    try {
      final response = await _send(
        base.replace(
          path: prefix == '/v8/management'
              ? '$prefix/requests/api-call'
              : '$prefix/api-call',
        ),
        key,
        method: 'POST',
        body: {
          'authIndex': '${file['auth_index'] ?? file['authIndex']}',
          'method': 'GET',
          'url': codex
              ? 'https://chatgpt.com/backend-api/wham/usage'
              : 'https://api.anthropic.com/api/oauth/usage',
          'header': header,
        },
      );
      if (response.statusCode != 200) {
        return account.withQueryFailure(
          '主动查询失败（管理接口 HTTP ${response.statusCode}）',
        );
      }
      final envelope = jsonDecode(utf8.decode(response.bodyBytes));
      if (envelope is! Map) return account.withQueryFailure('主动查询失败 · 返回格式不正确');
      final status = number(envelope['status_code'])?.toInt();
      if (status == null || status < 200 || status >= 300) {
        return account.withQueryFailure(
          status == 401
              ? '主动查询失败 · 认证失效（401）'
              : '主动查询失败（供应商 HTTP ${status ?? '未知'}）',
        );
      }
      var payload = envelope['body'];
      if (payload is String) payload = jsonDecode(payload);
      if (payload is! Map) return account.withQueryFailure('主动查询失败 · 返回格式不正确');
      return liveQuota(account, Json.from(payload), DateTime.now().toUtc()) ??
          account.withQueryFailure('主动查询未返回有效限额');
    } catch (_) {
      return account.withQueryFailure('主动查询失败 · 网络或返回格式异常');
    }
  }

  Future<AccountQuota> _grokQuota(
    Uri base,
    String prefix,
    String key,
    Json file,
    AccountQuota account,
  ) async {
    String? failure;
    AccountQuota? primary;
    AccountQuota? monthly;
    // Same read-only billing requests as the upstream auth-file quota screen.
    // Never use its paid-plan chat health probe: that would consume quota.
    for (final weekly in [true, false]) {
      try {
        final uri = base.replace(
          path: prefix == '/v8/management'
              ? '$prefix/requests/api-call'
              : '$prefix/api-call',
        );
        final header = <String, String>{
          'Authorization': 'Bearer \$TOKEN\$',
          'x-xai-token-auth': 'xai-grok-cli',
          'x-grok-client-version': '0.2.93',
          'accept': '*/*',
          'user-agent': 'grok-pager/0.2.93 grok-shell/0.2.93 (macos; aarch64)',
        };
        for (final record in [
          file,
          file['metadata'],
          file['attributes'],
          file['oauth'],
          file['user'],
          if (file['metadata'] is Map) file['metadata']['oauth'],
          if (file['metadata'] is Map) file['metadata']['user'],
          if (file['attributes'] is Map) file['attributes']['oauth'],
          if (file['attributes'] is Map) file['attributes']['user'],
        ]) {
          if (record is! Map) continue;
          final id =
              record['sub'] ??
              record['subject'] ??
              record['user_id'] ??
              record['userId'] ??
              (record == file ? null : record['id']);
          if (id != null && '$id'.trim().isNotEmpty) {
            header['x-userid'] = '$id';
            break;
          }
        }
        final response = await _send(
          uri,
          key,
          method: 'POST',
          body: {
            'authIndex': '${file['auth_index'] ?? file['authIndex']}',
            'method': 'GET',
            'url':
                'https://cli-chat-proxy.grok.com/v1/billing${weekly ? '?format=credits' : ''}',
            'header': header,
          },
        );
        if (response.statusCode != 200) {
          failure = '限额查询失败（管理接口 HTTP ${response.statusCode}）';
          continue;
        }
        final envelope = jsonDecode(utf8.decode(response.bodyBytes));
        if (envelope is! Map) {
          failure = '限额查询失败 · 返回格式不正确';
          continue;
        }
        final status = number(envelope['status_code'])?.toInt();
        if (status == null || status < 200 || status >= 300) {
          failure = status == 401
              ? '401 · Grok 认证失效'
              : '限额查询失败（Grok HTTP ${status ?? '未知'}）';
          continue;
        }
        var payload = envelope['body'];
        if (payload is String) payload = jsonDecode(payload);
        if (payload is! Map || payload['config'] is! Map) {
          failure = '服务未返回 Grok 账单限额';
          continue;
        }
        final result = account.withGrokBilling(Json.from(payload['config']));
        // Keep a real weekly window with unknown usage; do not replace its clock
        // with a different monthly balance, just as the upstream management UI.
        if (result != null) {
          if (weekly) {
            primary = result;
          } else {
            monthly = result;
          }
          continue;
        }
        failure = '服务未提供可计算的 Grok 剩余百分比';
      } catch (_) {
        failure = 'Grok 限额查询失败 · 网络或返回格式异常';
      }
    }
    if (primary != null) return primary.withBillingDetails(monthly);
    if (monthly != null) return monthly;
    return account.withProbe(failure: failure ?? 'Grok 限额查询失败');
  }

  Future<List<Json>> _plugins(Uri base, String prefix, String key) async {
    try {
      final response = await _get(base.replace(path: '$prefix/plugins'), key);
      if (response.statusCode != 200) return [];
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is! Map || value['plugins'] is! List) return [];
      return (value['plugins'] as List)
          .whereType<Map>()
          .map(Json.from)
          .where(
            (p) =>
                p['supports_quota'] == true &&
                p['effective_enabled'] == true &&
                p['registered'] == true &&
                '${p['id'] ?? ''}'.isNotEmpty,
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<http.Response> _get(Uri uri, String key) => _send(uri, key);

  Future<http.Response> _send(
    Uri uri,
    String key, {
    String method = 'GET',
    Json? body,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${key.trim()}',
        'Accept': 'application/json',
      });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return await (() async => http.Response.fromStream(
      await client.send(request),
    ))().timeout(const Duration(seconds: 15));
  }
}
