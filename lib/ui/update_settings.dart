import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../core/connection.dart';
import '../core/monitoring.dart';
import '../core/updates.dart';
import 'help_button.dart';

class UpdateSettingsPanel extends StatefulWidget {
  const UpdateSettingsPanel({super.key, this.repository});
  final UpdateRepository? repository;
  @override
  State<UpdateSettingsPanel> createState() => _UpdateSettingsPanelState();
}

class _UpdateSettingsPanelState extends State<UpdateSettingsPanel>
    with WidgetsBindingObserver {
  final client = http.Client();
  late UpdateRepository repository;
  String version = '';
  Map<String, dynamic> download = {};
  AppUpdate? latest;
  bool busy = false,
      refreshing = false,
      autoInstall = false,
      awaitingPermission = false;
  Timer? poll;
  @override
  void initState() {
    super.initState();
    repository = widget.repository ?? UpdateRepository(client);
    WidgetsBinding.instance.addObserver(this);
    initialize();
  }

  @override
  void dispose() {
    poll?.cancel();
    client.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(resume());
  }

  void notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  String error(Object e) => e is AppError
      ? e.message
      : e is PlatformException
      ? e.message ?? '更新操作失败'
      : '网络暂时不可用，请稍后重试';
  Future<void> initialize() async {
    try {
      final info = await quotaChannel.invokeMapMethod<String, dynamic>(
        'appVersion',
      );
      if (mounted) setState(() => version = '${info?['version'] ?? ''}');
      await refresh();
    } catch (_) {
      /* The update entry must not interfere with quota settings. */
    }
  }

  Future<void> resume() async {
    await refresh();
    if (!mounted || !awaitingPermission) return;
    awaitingPermission = false;
    if (download['canInstall'] == true) {
      await install();
    } else {
      notice('未允许安装应用，可稍后点击安装更新重试');
    }
  }

  Future<void> refresh() async {
    if (refreshing || !mounted) return;
    refreshing = true;
    try {
      final state = await quotaChannel.invokeMapMethod<String, dynamic>(
        'updateStatus',
      );
      if (!mounted) return;
      setState(() => download = state ?? {});
      if (download['state'] == 'running' || download['state'] == 'paused') {
        poll ??= Timer.periodic(const Duration(seconds: 1), (_) => refresh());
      } else {
        poll?.cancel();
        poll = null;
      }
      if (download['state'] == 'ready' &&
          autoInstall &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true) {
        autoInstall = false;
        await install();
      }
    } catch (_) {
      /* DownloadManager keeps the download alive across navigation. */
    } finally {
      refreshing = false;
    }
  }

  Future<void> check() async {
    setState(() => busy = true);
    try {
      latest = await repository.check(version);
      if (!mounted) return;
      if (latest == null) {
        notice('已是最新版本');
        return;
      }
      final update = latest!;
      final notes = update.notes.length > 600
          ? '${update.notes.substring(0, 600)}…'
          : update.notes;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('发现新版本 v${update.version}'),
          content: SingleChildScrollView(
            child: Text(notes.isEmpty ? '下载后将打开系统安装页面，保留现有配置。' : notes),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('下载更新'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) await start(update);
    } catch (e) {
      notice(error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> start(AppUpdate update) async {
    await quotaChannel.invokeMethod<int>('startUpdate', update.toJson());
    autoInstall = true;
    await refresh();
  }

  Future<void> install() async {
    if (busy && !autoInstall && download['state'] != 'ready') return;
    setState(() => busy = true);
    try {
      final state = await quotaChannel.invokeMethod<String>('installUpdate');
      awaitingPermission = state == 'permission';
    } catch (e) {
      if (mounted) setState(() => download = {...download, 'state': 'failed'});
      notice(error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancel() async {
    try {
      autoInstall = false;
      await quotaChannel.invokeMethod<void>('cancelUpdate');
      await refresh();
    } catch (e) {
      notice(error(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        download['state'] == 'running' || download['state'] == 'paused';
    final ready = download['state'] == 'ready';
    final progress = (download['progress'] as num? ?? -1).toDouble();
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    version.isEmpty ? '应用更新' : '应用更新 · v$version',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const HelpButton(
                  title: '应用更新',
                  text:
                      '点击检查更新，从项目 GitHub 发布页获取新版 APK。下载可在后台继续，回到本页可继续安装。\n\n安装前核对应用名称、版本和签名，有校验值时同时验证文件。首次安装可能需要允许本 App 安装应用，最后由系统确认安装；覆盖安装保留配置。',
                ),
              ],
            ),
            if (active) ...[
              Text(
                download['state'] == 'paused'
                    ? '等待网络，下载稍后继续'
                    : '正在下载 v${download['version']}${progress >= 0 ? ' · ${(progress * 100).round()}%' : ''}',
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress >= 0 ? progress : null),
              TextButton(onPressed: cancel, child: const Text('取消下载')),
            ] else ...[
              if (download['state'] == 'failed') const Text('更新未完成，请重新检查或下载'),
              FilledButton.tonal(
                onPressed: busy || version.isEmpty
                    ? null
                    : ready
                    ? install
                    : check,
                child: Text(
                  busy
                      ? '请稍候…'
                      : ready
                      ? '安装更新'
                      : '检查更新',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
