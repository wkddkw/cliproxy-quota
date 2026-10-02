# 管理接口适配

核对来源：[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)，
源码版本 `6fecc6e5567912661654a4eaf9b8f5436facd1c2`（2026-10-02）。

| 操作 | v8 | v7 / 兼容层 |
| --- | --- | --- |
| 认证文件与被动限额 | GET /v8/management/credentials | GET /v0/management/auth-files |
| 发现已启用的限额插件 | GET /v8/management/plugins | GET /v0/management/plugins |
| 查询插件限额 | GET /v8/management/plugins/:id/quota?auth_index=… | GET /v0/management/plugins/:id/quota?auth_index=… |

上游没有注册裸 `/v8/management` 或 `/v0/management` 的 GET 路由。因此通过真实认证文件资源探测版本：v8 请求仅在 HTTP 404 时回退 v0；401、403、超时、服务错误均不回退。每个请求带 `Authorization: Bearer <管理密钥>`。禁止自动跟随重定向，避免把密钥发送到另一个地址。

认证文件响应是 `{"files": [...]}`。只保存显示所需字段，不下载认证文件，不持久化完整响应。Codex 读取 `quota.signals` 中的 `X-Codex-Primary/Secondary-Used-Percent`、`Window-Minutes`、`Reset-At` / `Reset-After-Seconds`；Claude 读取 `Anthropic-Ratelimit-Unified-5h/7d-Utilization` 与 `Reset`。重置秒数以服务提供的 `quota.observed_at` 为起点。不会把 cooldown、unavailable、Retry-After 推算为百分比。

通过 `plugins` 中 `supports_quota`、`registered`、`effective_enabled` 和 `quota_provider` 自动发现供应商的实际限额能力。插件 GET 是查询操作，上游会在服务器端执行 `fetchQuotaForPlugin`，可能向供应商请求最新限额；手机只向用户的 CLIProxyAPI 发送请求，不向供应商发送请求。查询最多同时进行四个。

插件响应读取 `groups[].buckets[]`：`window`、`remainingFraction` / `remaining_fraction`、`resetTime` / `reset_time`。比例必须在 0–1 内，0 表示真实耗尽，缺失不当作 0。优先 5h 窗口，多个相同主窗口取最低；没有 5h 时使用实际返回的窗口，并保守取其中最低剩余。

供应商归并后百分比取所有账号的最低值。如果存在没有数据或不可用的账号，总览显示 `—` 并提示查看原因，避免已知账号的高额度掩盖未知账号。认证文件明细仍展示已取得的百分比和原因。

Grok 等供应商不会仅因名称被判为不支持：存在已启用的匹配插件时查询真实限额。确实没有被动限额或匹配插件时，App 显示“暂不支持”，供应商不写入通知汇总缓存。已支持但暂时没有观测值的账号显示“服务尚未返回限额数据”，查询失败显示“探测失败”。没有可读接口的声明式 quota_probe 暂不能主动调用：声明式探测尚未启用。

原生通知汇总缓存只含供应商名、圆标字符、账号数、最低百分比、异常数和刷新时间；不含地址、密钥、邮箱、文件名或原始错误。插件错误体不会显示或缓存。清除连接也清除本机密钥、App 缓存和通知汇总缓存。

## Codex / Claude 主动查询

v0.1.4 起，手动刷新、打开 App 刷新、Android 后台检查都会通过管理代理 POST `/v8/management/requests/api-call` 或 `/v0/management/api-call` 发起固定 URL 的 GET：Codex `https://chatgpt.com/backend-api/wham/usage`，Claude `https://api.anthropic.com/api/oauth/usage`。认证索引与 `$TOKEN$` 占位符由服务器解析，手机不持有供应商凭证。Codex 支持管理响应 `id_token.chatgpt_account_id` 作为账号头；不执行聊天、额度重置、积分兑换或订阅修改。

Codex 解析 `rate_limit.primary_window / secondary_window` 的 `used_percent`、`limit_window_seconds`、`reset_at / reset_after_seconds`，优先有效 5 小时窗口，显式 0 秒窗口过滤。Claude 主动接口的 `utilization` 是 0–100 百分比，与被动 header 的 0–1 比例分开处理。只把成功且含有效限额的响应标为「额度查询于」；失败或格式异常保留服务器原始值与时间，标注查询失败和旧数据，并禁止相应供应商触发消耗提醒。缺少认证索引时明确说明无法主动查询。禁用账号不查询；OAuth 账号临时不可用时仍允许只读查询，以便看到恢复后的额度。

## Grok 认证文件页兼容

Grok CLI / xAI 认证文件还通过管理代理查询账单：POST `/v8/management/requests/api-call` 或 `/v0/management/api-call`，内部方法固定为 GET，仅允许 `https://cli-chat-proxy.grok.com/v1/billing?format=credits` 与 `/v1/billing` 两个账单 URL。请求携带认证索引和 `$TOKEN$` 占位符，供应商凭证由 CLIProxy 在服务器端填充。手机不读取、上传或持有供应商 token。此 POST 是只读查询的封装，不编辑配置或账号。不会照搬上游付费账户的聊天健康探测，避免消耗额度。

`config.creditUsagePercent` 作为周窗口已用百分比；月窗口的 `monthlyLimit` / `used`（数值或 `{val: ...}`）按上游 cents 语义转换为 USD。周限额和月金额分别保留周期，月账单不会覆盖周窗口的未知百分比。账单错误显示查询失败，不再自动标为“暂不支持”。

## 绝对额度

App 按周期保存和展示 Token / USD 的总额、已用和剩余，仅在接口返回绝对数值和明确单位时展示；有两个绝对数值时可计算第三个。不会从百分比、积分或订阅价格推算 Token / USD。插件 buckets 的显式 token / USD 字段和规范 summary 中带明确单位的额度指标可展示。未提供周期的 summary 单独标注周期未提供，不能挂到 5 小时窗口上。无绝对额度时隐藏对应 Token / USD 栏。绝对额度不进入原生通知汇总缓存。显式非正数窗口无效，不展示或参与主限额计算。

本项目不调用 config、认证上传/删除/刷新、登录、reset、usage-queue 接口。api-call 仅用于上述固定的 Codex / Claude GET 限额查询和 Grok GET 账单查询。

## Android 后台通知

开启后使用 WorkManager，最短约 15 分钟，仅请求用户保存的管理服务。首次观察、周期变化或额度回升建立基准；支持累计下降和固定刻度两种方式，默认 5 个百分点。账号不完整时不提醒。连接版本标记和原生同步锁拒绝切换服务器、清除数据、关闭监测后到达的旧响应，前后台共用基准防止重复提醒。后台仅写供应商汇总缓存，账号标识只参与不可逆周期摘要。
