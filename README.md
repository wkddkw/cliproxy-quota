# CLIProxy 限额

[![Build and test](https://github.com/wkddkw/cliproxy-quota/actions/workflows/ci.yml/badge.svg)](https://github.com/wkddkw/cliproxy-quota/actions/workflows/ci.yml)

只读的 CLIProxyAPI 手机 App，支持 Android 和 iPhone。按供应商归并账号、显示最低剩余额度，点击供应商查看认证文件和周期明细；Android 可按消耗百分比提醒。

![连接设置、供应商总览、认证文件明细和通知示意](docs/images/app-preview.png)

*界面示意，使用示例数据；通知样式和悬浮效果由手机系统决定。*

**[下载 Android 预览版 v0.1.5](https://github.com/wkddkw/cliproxy-quota/releases/tag/v0.1.5) · [构建记录](https://github.com/wkddkw/cliproxy-quota/actions) · [接口说明](docs/api-contract.md)**

## 使用

1. 安装 App，确认手机能通过 Tailscale / 家庭 VPN 访问自己的 CLIProxyAPI。
2. 填写服务器地址和**管理密钥**（`secret-key` 或 `MANAGEMENT_PASSWORD`），点击「保存并连接」。默认端口 8317；自定义端口、HTTPS 在「更多」中填写。完整管理页地址会自动去掉管理路径。
3. 总览下拉刷新会主动查询 Codex / Claude / Grok 的限额；点开供应商查看账号、剩余百分比、周期和重置时间。周周期显示「每周限额」，无效的 0 分钟窗口不会显示。
4. Token / USD 仅在接口提供真实绝对数值时展示；没有数据就隐藏，不根据百分比猜算。Keeper 的累计 Token 用量不等于官方周期总额或剩余额度，当前没有接入 Keeper。
5. Android 设置 →「限额通知」，开启常驻监测后允许通知权限，服务会立即查询一次，然后按周期计划检查。默认每累计下降 **5 个百分点**提醒一次，可设置 1–100；也可选择已用经过固定百分比刻度。首次有效检查、周期变化、额度回升时建立新基准，不立即提醒。
6. 开启监测时显示常驻限额概览，可以隐藏通知内容，并点击「发送测试通知」检查权限和系统提醒效果。修改比例等选项后点击「保存通知设置」。

常驻监测可选约 15 / 30 / 60 分钟；使用数据同步前台服务、服务内计时和非精确的唤醒闹钟。设置页分别显示最近后台检查、下次计划、服务状态和失败原因，前台刷新不会改写后台检查时间。通知提供「立即检查」「停止监测」，停止会同步关闭 App 设置。省电、强行停止或 VPN 断开仍可能导致延迟。

Android 14+ 允许用户单独划掉普通常驻通知，划掉不代表停止服务。Android 15+ 数据同步前台服务后台累计限时 6 小时（用户回到 App 后系统重置计时），到时停止常驻服务并继续 WorkManager 系统定期检查，打开 App 可恢复。未将本 App 伪装成 VPN、媒体播放或通话；不能承诺在 ColorOS 16 完全不可划掉或全天准时。打开 App 刷新也会检查。通知针对供应商最低剩余百分比，有账号缺失或失败时不发消耗提醒，不代表逐次 Token 消耗计量。

**v0.1.3 暂时关闭 Android / iOS 小组件及添加入口。普通 Android 通知已经实现，OPPO / 一加负一屏、ColorOS 流体云尚未接入。** [设备与验证状态](docs/device-compatibility.md) · [负一屏接入条件](docs/oppo-minus-one-screen.md)。

v0.1.1 / v0.1.2 可直接覆盖安装，保留连接信息。v0.1.0 使用不同临时签名，首次升级需要卸载后重装。

## 数据如何流动

![CLIProxyAPI 到手机汇总缓存与 Android 通知的数据流](docs/images/data-flow.png)

## 限额能力

- v8 优先，只有 404 才回退 v0；地址、密钥和远程访问错误分别提示。
- Codex / Claude 每次刷新通过服务器主动查询官方 OAuth 限额接口；查询失败明确显示旧数据及原始记录时间。其他供应商使用服务器启用的限额插件。解析真实 `groups → buckets → remainingFraction`；Grok 使用与认证文件页一致的只读账单查询。
- 优先 5 小时窗口，否则使用实际返回的主窗口。多个账号显示最低剩余，不取平均。
- 不支持的供应商在 App 标注「暂不支持」；已支持但缺少数据或查询失败显示原因，不伪造百分比。有账号不可用时总览显示 `—`，已知账号仍可在明细查看。
- Token / USD 按周期保留；不同周期不混算，仅在有两个真实绝对数值时计算第三个。

## 构建

Flutter **3.47.6 stable**、Java 17；Android 7.0+、iOS 17.0+。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
# Android 原生提醒规则测试
cd android
./gradlew :quota_platform:testDebugUnitTest
# macOS + Xcode
flutter build ios --release --no-codesign
```

[GitHub Actions](https://github.com/wkddkw/cliproxy-quota/actions) 执行静态检查、Flutter 测试、Android 原生测试、APK 和 iOS 未签名构建。APK 使用固定预览签名，签名私钥存于仓库加密 Secrets，不提交公开代码。

iOS 未签名构建**不能直接安装到 iPhone**。在 Xcode 打开 `ios/Runner.xcworkspace`，为 Runner 设置自己的 Apple Developer Team / Bundle Identifier，选择设备运行或 Archive / TestFlight。当前工程没有启用 WidgetKit 扩展；`scripts/configure_ios_app.rb` 可重复清理旧扩展注册。消耗通知目前仅在 Android 实现。

## 数据与范围

管理密钥存于 Android Keystore 支持的加密存储 / iOS Keychain。地址和认证文件显示数据保存在本机。原生通知汇总缓存不含密钥、邮箱或文件名；锁屏公开版本只提示打开 App，可进一步隐藏全部通知内容。没有分析 SDK、云端代理或凭证上传。默认 HTTP 适用于可信 VPN；可在「更多」启用 HTTPS。

所有请求发到用户配置的 CLIProxyAPI。Codex / Claude 限额与 Grok 账单通过管理代理执行只读查询，不执行付费聊天健康探测，不编辑服务器配置、不上传或删除认证文件、不重新登录、不重置额度、不读取消费型 usage-queue。

「清除这台服务器」会移除本机地址、管理密钥和缓存，关闭后台监测并撤回通知。
