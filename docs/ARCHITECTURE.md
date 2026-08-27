# 架构与移植契约

本项目的主形态是**注入 Mirasim 客户端界面的控件**，macOS 菜单栏只是兜底显示面。
控件与它同数据侧之间的契约与平台无关，故换平台时只需重写喂数据的常驻进程（下称 provider），
控件与注入流程可原样搬。本文写明三层职责、两份契约与一张移植清单。

## 三层

```
provider（常驻进程，当前为 Swift/macOS）
 ├─ 采数：Mirasim 本地接口 + 本机账本文件
 ├─ 算数：标定 / 推算 / 速度回归，五级降级
 ├─ 供数：回环 HTTP 上挂 quota.json                ── 契约 A
 └─ 注入：CDP 巡检，把 widget.js 送进渲染进程       ── 契约 B
                     │
widget（widget/miraquota-widget.js，Shadow DOM，纯 JS，无外部依赖）
 └─ 每 5 秒 fetch quota.json 绘制；有在途请求时提到 2 秒
```

provider 与 widget 之间只有 HTTP，没有共享文件、没有 IPC。widget 不读磁盘，
也读不到磁盘：渲染进程取不到 `~/.claude/projects` 与网关账本，美元与速度只能由 provider 喂。

## 契约 A：数据 feed

| 项 | 约定 |
|---|---|
| 地址 | `http://127.0.0.1:4988/quota.json`，端口被占用时向后顺延至 4995 |
| 绑定 | 只绑回环。绑 `0.0.0.0` 会把本机用量暴露到局域网 |
| 缓存 | 响应头带 `Cache-Control: no-store`；控件另加 `?t=<时间戳>`，故**路由匹配必须剥掉查询串** |
| CORS | 渲染进程的页面源是 `file://`，响应必须带 `Access-Control-Allow-Origin: *`，并在 `Access-Control-Allow-Headers` 里列出 `X-MiraQuota-Token`，否则带令牌的 POST 过不了预检 |
| 退出 | `POST /quit`，须带 `X-MiraQuota-Token`（值存 `~/.miraquota/feed.token`，0600，跨启动稳定）。GET 与裸 POST 一律 404：回环端口上任何网页都能发出不经预检的请求，无令牌校验时任意被访问的网页都能把 provider 关掉 |
| 开窗 | `POST /open`，令牌同上。macOS 版用它做单实例转交：第二次点应用图标的进程拿不到实例锁，把开窗意图递给常驻实例后自退。无窗口形态的 provider 不实现即可，控件不依赖它 |
| 端口自发现 | 控件失联时在 4988–4995 内自行重找，因此持久注入脚本里烤着的旧端口不会造成失联 |

`quota.json` 根字段：

| 字段 | 类型 | 含义 |
|---|---|---|
| `state` | string | 降级级别键：`exact` / `live` / `stale` / `reckoned` / `local` |
| `stateLabel` | string | 该级别的显示名 |
| `measured` | bool | 是否为实测（非推算） |
| `detail` | string? | 当前级别的补充说明，控件作横幅显示 |
| `capturedAt` | number | 采集时刻，unix 秒。控件据此判断数据是否发霉 |
| `mode` / `host` / `relayStatus` | string | 线路、relay 主机、relay 状态 |
| `pricing` | string | 价目表来源：`models.dev cache` 或 `builtin` |
| `buckets` | number | 账本的分钟桶数量，仅作自检 |
| `unitPriceUSD` | number? | 额度点单价，美元/点。由账本支出 ÷ 已用点数反推，取不到即缺省 |
| `unitPriceNotice` | string? | 兜底单价停用的原因。逐窗口反推的每点美元离散超 4 倍即判账本与点数不自洽，此时 `unitPriceUSD` 缺省，界面在页脚显示本串 |
| `accountNotice` | string? | 账号状态提示（`suspended` / `unmetered` / `degraded`） |
| `windows` | array | 每个额度窗口一项，见下 |
| `speed` | object? | 速度卡数据，见下 |

`windows[]`：

| 字段 | 类型 | 含义 |
|---|---|---|
| `label` | string | `5h` / `7d` / `7d_fable`。**窗口集合不固定，界面不得写死两个** |
| `usedPercent` | number | 0–100。`inferred` 为真时是推算值 |
| `scaledSpentUSD` | number? | 按点数口径折算的已用美元（`满额 × 百分比`），仅 exact/live 两级有值。**主行显示它**，与百分比、进度条同分母；缺省而 `fullUSD` 也缺省时主行改显 `points.used`，账本支出不得抬到主行 |
| `spentUSD` | number | 本机账本支出，作副行「账本 $x」 |
| `fullUSD` | number? | 该窗口的满额，回归标定优先 |
| `remainingUSD` | number? | 余额 |
| `points` | object? | `{used, budget}`，来自 `/v1/limits` 的原始额度点 |
| `resetAt` | number? | 重置时刻，unix 秒 |
| `pacePercent` / `paceDelta` | number? | 均速游标位置与偏离 |
| `etaSeconds` | number? | 按当前速度打满所需秒数 |
| `confidence` | string | 标定置信度 |
| `inferred` | bool | 真值表示百分比来自推算，界面须加 `≈` |

`speed`：`recentCount`、`sampleTotal`、`inflight`（在途起始时刻，unix 秒，非空即「生成中」）、
`measuredTurnTTFB`（`{median, count}`），以及 `rows[]`：`model`、`samples`、`latestAt`、
`ttft`、`rate`、`endToEnd`、`baselineRate`、`drift`、`driftNotable`。
**阈值由 provider 判定后以 `driftNotable` 下发，两个显示面不各自定阈值。**

## 契约 B：注入

provider 侧要做到的六条，缺一条都有确定的故障形态：

1. **探端口**：`GET http://127.0.0.1:<port>/json` 列 target。端口顺序为环境变量
   `MIRAQUOTA_CDP_PORT` → 9333 → 9222。
2. **每 target 只登记一次** `Page.addScriptToEvaluateOnNewDocument`。重复登记会让页面刷新时
   同一段脚本跑上几十遍。
3. **判在场靠探针，不靠 target id**：每轮 `Runtime.evaluate` 读 `window.__miraquotaVersion`，
   缺失或低于源码里的 `VERSION` 才注入。按 id 去重不行——页面刷新后 id 不变而控件已没了。
4. **版本号必须随控件改动递增**。控件 boot 时先调旧实例的 `window.__miraquotaTeardown()`
   断开 observer 与定时器再摘宿主；**绝不能把新版本热替换到跑着 v6 及更早控件的页面上**，
   那种页面先重载再注（旧实例的 observer 与新实例互删互挂，形成不落地的微任务循环，
   渲染进程主线程 100%+ CPU，此后所有 `Runtime.evaluate` 一律超时）。
5. **一个页面端点同一时刻只接受一个 CDP 客户端**：`/devtools/page/<id>` 上滞留的 WebSocket
   会把后续探测全挡在门外。连接必须收干净，或改走浏览器级端点
   （`/json/version` 的 `webSocketDebuggerUrl` + `Target.attachToTarget(flatten:true)`）。
6. **巡检节奏**：10 秒一轮；「全部页面都带着最新控件」连续三轮后退避到 30 秒，任何一轮落空
   立刻回到 10 秒。

控件侧对宿主的三个要求，移植时不必改动但需知道：渲染进程 CSP 为 `script-src 'self'`
（外部 script 标签加载不了，CDP 执行不受此限），`connect-src` 放行 `http://127.0.0.1:*`；
控件全部 `localStorage` 访问都在 try/catch 里（不透明源会直接抛）；控件暴露
`__miraquotaVersion` / `__miraquotaState` / `__miraquotaError` / `__miraquotaTeardown`
四个把手，注入环境没有控制台，排查只能靠它们。

## 移植清单

仓库里的 [provider-node/miraquota-provider.mjs](../provider-node/miraquota-provider.mjs)
已按下表实现了不依赖账本的那一半（三个平台的进程与端口枚举都在里面），可直接用或作起点。

| 能力 | macOS 现在的做法 | 移植时 |
|---|---|---|
| CDP 探测与注入 | `URLSession` + `URLSessionWebSocketTask` | 任何 HTTP/WS 客户端。Node 22+ 自带 `WebSocket`，一个 `.mjs` 即可跑通 |
| feed HTTP 服务 | `Network.framework` 的 `NWListener` | 任意 HTTP server，**必须只绑 127.0.0.1** |
| Mirasim 路由端口发现 | `ps` 解析 `server.cjs serve --port N`，再 `lsof -p <pid>` 枚举该进程的回环监听口 | Windows 用 `Get-CimInstance Win32_Process` 取命令行 + `netstat -ano` 按 pid 过滤；Linux 用 `/proc/<pid>/cmdline` + `ss -tlnp` |
| 账本与诊断文件 | `~/.claude/projects/*/*.jsonl`、`~/.mirasim/{insights,diag,analytics}` | 路径同为用户主目录下同名目录，格式与平台无关 |
| 状态落盘 | `~/.miraquota/`（账本游标、标定样本、窗口锚点、feed 令牌、单实例锁） | 同构即可；单实例锁要带约 3 秒重试，重启时新旧实例会短暂重叠 |
| 常驻自启 | LaunchAgent（`LimitLoadToSessionType=Aqua`，`KeepAlive.SuccessfulExit=false`） | Windows 计划任务（登录触发）或 systemd user unit |
| 让 Mirasim 带调试端口启动 | 生成一个 `.app` 启动器，`open -na Mirasim --args --remote-debugging-port=9333` | 快捷方式追加同一参数即可。Mirasim 只从命令行接受该参数，没有环境变量或配置项 |
| 兜底显示面 | AppKit 状态栏项 + SwiftUI 弹层，另有一个可从 Dock 打开的主窗口（额度 / 速度 / 自检 / 关于） | 可省。控件是主显示面，兜底缺失时只是注入不可用期间看不到数字 |

移植后用 `scripts/fake-mirasim.py` 验证协议容忍度与降级路径，不必依赖真实 Mirasim：
它伪造换过键名与刻度的 relay 帧（`renamed`）以及完全无法识别的帧（`garbage`）。

## 不属于契约的部分

满额标定、速度回归、五级降级的判定口径都在 provider 内部，换实现可以换算法；
但两个显示面必须共用同一份判定结果（`state`、`driftNotable`、`inferred` 等由 provider 下发），
显示侧各自定阈值会让两个面在同一时刻给出不同结论。口径的推导见 README 的
「满额怎么来」「出字速度与首 token 怎么来」「读不到时怎么办」三节。
