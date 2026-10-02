import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'models.dart';

class ConnectionSettings {
  const ConnectionSettings({
    required this.server,
    this.port = 8317,
    this.fullAddress = '',
  });
  final String server;
  final int port;
  final String fullAddress;
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
      if (path.isNotEmpty) throw const AppError('完整地址只能包含主机、端口及管理页面后缀');
      return parsed.replace(path: '');
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

  Json toJson() => {'server': server, 'port': port, 'fullAddress': fullAddress};
  factory ConnectionSettings.fromJson(Json json) => ConnectionSettings(
    server: json['server'] as String,
    port: json['port'] as int,
    fullAddress: json['fullAddress'] as String,
  );
}

class AppError implements Exception {
  const AppError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ManagementApi {
  ManagementApi(this.client);
  final http.Client client;
  Future<QuotaSnapshot> refresh(ConnectionSettings settings, String key) async {
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
        throw AppError('服务请求失败（HTTP ${response.statusCode}），可稍后重试');
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
            if (file['disabled'] == true ||
                file['status'] == 'disabled' ||
                file['unavailable'] == true ||
                file['status'] == 'error') {
              return;
            }
            final rawProvider = '${file['provider'] ?? file['type'] ?? ''}'
                .toLowerCase();
            final plugin = plugins
                .where(
                  (p) => '${p['quota_provider']}'.toLowerCase() == rawProvider,
                )
                .firstOrNull;
            if (plugin == null || '${file['auth_index'] ?? ''}'.isEmpty) return;
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
          }),
        );
      }
      return QuotaSnapshot(DateTime.now().toUtc(), accounts);
    } on AppError {
      rethrow;
    } on TimeoutException {
      throw const AppError('连接超时，请检查服务器和 VPN / Tailscale');
    } on SocketException {
      throw const AppError('无法连接服务器，请检查网络、VPN 和「更多」中的地址');
    } on http.ClientException {
      throw const AppError('网络连接失败，请检查服务器地址及 HTTPS 证书');
    } on FormatException {
      throw const AppError('接口返回的不是有效 JSON，请检查完整地址');
    }
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

  Future<http.Response> _get(Uri uri, String key) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${key.trim()}',
        'Accept': 'application/json',
      });
    return await (() async => http.Response.fromStream(
      await client.send(request),
    ))().timeout(const Duration(seconds: 15));
  }
}
