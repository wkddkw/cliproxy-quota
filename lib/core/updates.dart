import 'dart:convert';
import 'package:http/http.dart' as http;
import 'connection.dart';

class AppVersion implements Comparable<AppVersion> {
  AppVersion(this.parts);
  final List<int> parts;
  static AppVersion? parse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 3; i++) int.tryParse(match.group(i)!)];
    if (parts.any((part) => part == null)) return null;
    return AppVersion(parts.cast<int>());
  }

  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.url,
    required this.notes,
    this.digest = '',
  });
  final String version, url, notes, digest;
  Map<String, String> toJson() => {
    'version': version,
    'url': url,
    'digest': digest,
  };
}

class UpdateRepository {
  UpdateRepository(this.client);
  final http.Client client;
  Future<AppUpdate?> check(String installedVersion) async {
    final current = AppVersion.parse(installedVersion);
    if (current == null) throw const AppError('无法识别当前版本');
    final response = await client
        .get(
          Uri.https('api.github.com', '/repos/wkddkw/cliproxy-quota/releases', {
            'per_page': '30',
          }),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'CLIProxy-Quota',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const AppError('检查过于频繁，请稍后重试');
    }
    if (response.statusCode != 200) throw const AppError('暂时无法检查更新，请稍后重试');
    final data = jsonDecode(response.body);
    if (data is! List) throw const AppError('更新信息无效，请稍后重试');
    AppUpdate? latest;
    var latestVersion = current;
    for (final release in data) {
      if (release is! Map || release['draft'] == true) continue;
      final tag = release['tag_name'];
      if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
        continue;
      }
      final version = AppVersion.parse(tag);
      if (version == null || version.compareTo(latestVersion) <= 0) continue;
      final assets = release['assets'];
      if (assets is! List) continue;
      for (final asset in assets) {
        if (asset is! Map || asset['name'] != 'cliproxy-quota-$tag.apk') {
          continue;
        }
        final expected =
            'https://github.com/wkddkw/cliproxy-quota/releases/download/$tag/cliproxy-quota-$tag.apk';
        if (asset['browser_download_url'] != expected) continue;
        final digest = asset['digest'];
        if (digest != null &&
            (digest is! String ||
                !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest))) {
          continue;
        }
        latest = AppUpdate(
          version: tag.substring(1),
          url: expected,
          notes: '${release['body'] ?? ''}',
          digest: digest as String? ?? '',
        );
        latestVersion = version;
        break;
      }
    }
    return latest;
  }
}
