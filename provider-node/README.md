# 参考 provider（跨平台）

一份按 [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) 两份契约实现的最小 provider，
用来在 Windows / Linux 上把控件放进 Mirasim 界面。控件（`../widget/miraquota-widget.js`）原样使用，
不需要改动。仓库主体的 Swift 实现是 macOS 上的完整版，这里只覆盖不依赖账本的那一半。

依赖只有 Node 22 或更新（`fetch` 与 `WebSocket` 自 Node 22 起是全局的），无需 npm install。

## 跑起来

```bash
# 1. Mirasim 带调试端口启动（Windows 在快捷方式的目标后追加同一参数）
#    macOS/Linux: open -na Mirasim --args --remote-debugging-port=9333
# 2. 起 provider
node provider-node/miraquota-provider.mjs

node provider-node/miraquota-provider.mjs --once        # 取一次并打印，用于自检
node provider-node/miraquota-provider.mjs --help        # 全部选项
```

常驻方式按平台自理：Windows 用「计划任务」登录触发，Linux 用 systemd user unit，
macOS 上直接用仓库主体的 Swift 版本。

### Windows 上多一步：会话令牌要手工给

现行 Mirasim 的 `/v1/limits` 要求带会话令牌，该令牌只存在于 Mirasim 拉起的会话进程的环境变量里。
macOS 与 Linux 用 `ps eww` 读得到，Windows 的 `Get-CimInstance` 不暴露进程环境，
`sessionTokens()` 在该平台直接返回空。所以 Windows 上要自行取到令牌并传进来：

```powershell
node provider-node\miraquota-provider.mjs --router-token <令牌>
# 或 $env:MIRAQUOTA_ROUTER_TOKEN = '<令牌>'
```

不给令牌时 `/v1/limits` 取不到，provider 退回 relay 帧的百分比口径——分辨率 0.1%，没有额度点数。

## 覆盖范围

| 有 | 无 |
|---|---|
| 额度点（`used`/`budget`）与百分比，取自路由端口的 `/v1/limits` | 美元金额、额度点单价（需解析 `~/.claude/projects` 与网关账本） |
| 重置倒计时、均速游标与偏离（由窗口长度与 `reset_at` 算出） | 满额标定（需账本支出对点数增量的观测序列） |
| 账号状态位（`suspended`/`unmetered`/`degraded`） | 速度卡（出字速度、首 token、在途「生成中」） |
| relay 帧退路（旧版 Mirasim 无 `/v1/limits` 时取 0.1% 分辨率的百分比） | 离线推算（需落盘窗口锚点）与「已过期」之后的两级降级 |
| 契约 A 的 feed：`quota.json` + 带令牌的 `POST /quit` | — |
| 契约 B 的注入：探针判在场、每 target 只登记一次、10/30 秒退避 | — |

缺的字段一律省略而不是填零。控件对此是容忍的：满额位置显示「标定中」，主行金额显示 `—`，
速度卡整块不出现，页脚那一行按有值的部分拼。要补齐美元与速度，按契约文档的字段表填
`scaledSpentUSD`、`spentUSD`、`fullUSD`、`unitPriceUSD`、`unitPriceNotice`、`speed` 即可，控件侧不用改。

relay 帧退路只走常规键名，不含 Swift 版的键名回退与有界深搜；刻度判定沿用「整帧证据」的做法
（窗口与历史缓冲的取值全部落在 (0,1] 才按小数换算）。

## 与 macOS 版并存

两者都会占 4988–4995 的 feed 端口并向同一个调试端口注入，同机同时跑会互相抢：
控件按端口区间自行发现 feed，可能连到另一个 provider 上。同机验证时给 Node 版
`--feed-port`（区间外，例如 4996）与 `--cdp-port`（另一个浏览器实例），注入的前导脚本
会把控件的 feed 地址固定到指定端口。

## 已验证

在本机 Chromium 151 上端到端跑通：`--cdp-port 9444 --feed-port 4996` 注入一个 http 源的替身页面，
控件 v18 挂载成功（`__miraquotaVersion=18`，`__miraquotaError` 为空），读到的是 Node 版的 feed，
三个窗口（5h / 7d / 7d_fable）的百分比与点数与同时刻 Swift 版 `--once` 的输出一致
（4.0% / 26.1% / 6.2%，均速偏离 −9.4 / +11.3 / −8.6），展开层无 `undefined` 残留。

未在 Windows 与 Linux 上实机验证：这两个平台的进程与端口枚举分别走
`Get-CimInstance` + `netstat -ano` 与 `ps` + `ss -Hltnp`，代码在仓库里，
但没有对应机器可跑。移植者先用 `--once` 确认端口发现，再起常驻。

控件本身不含平台假设：它是纯 DOM 加 Shadow DOM，跑在 Mirasim 的渲染进程里，
`backdrop-filter`、`-webkit-app-region`、`::-webkit-scrollbar` 在三个平台的 Chromium 上一致。
字体栈已含 `Segoe UI` 与微软雅黑；标题栏吸附按宿主底色的连续段实测得出，不按写死的坐标，
但各平台标题栏布局不同，吸附落位需实机核对。
