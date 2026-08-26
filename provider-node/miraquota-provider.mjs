#!/usr/bin/env node
/**
 * MiraQuota 参考 provider（跨平台，Node 22+）
 *
 * 按 docs/ARCHITECTURE.md 的两份契约实现最小可用的一份：
 *   契约 A  在回环 HTTP 上挂 quota.json
 *   契约 B  CDP 巡检，把 widget.js 注入 Mirasim 渲染进程
 *
 * 覆盖范围：额度点、百分比、重置倒计时、均速游标。
 * 不覆盖：美元金额、满额标定、速度卡、离线推算——这些要解析本机账本，
 * 见 provider-node/README.md「缺什么」。控件对这些字段缺失是容忍的。
 *
 * 依赖只有 Node 内置件（fetch 与 WebSocket 自 Node 22 起是全局的）。
 */

import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

const HERE = dirname(fileURLToPath(import.meta.url));
const STATE_DIR = join(homedir(), '.miraquota');
const TOKEN_FILE = join(STATE_DIR, 'feed.token');

const FEED_LO = 4988, FEED_HI = 4995;      // 契约 A：控件在这个区间里自行重找
const CHANNEL_DEFAULT = 4970;              // mirachannel 端口的惯用值
const POLL_MS = 15_000;                    // 取数间隔，与 Swift 实现一致
const SWEEP_MS = 10_000, SWEEP_IDLE_MS = 30_000, STEADY_ROUNDS = 3;
const WINDOW_SECONDS = { '5h': 5 * 3600, '7d': 7 * 86400, '7d_fable': 7 * 86400 };

/* ---------------- 参数 ---------------- */

const argv = process.argv.slice(2);
const flag = (name) => argv.includes('--' + name);
const opt = (name, fallback) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

if (flag('help') || flag('h')) {
  console.log(`用法 node miraquota-provider.mjs [选项]

  --once                取一次并打印，不起服务、不注入
  --no-inject           只提供 feed，不做 CDP 注入
  --cdp-port <N>        Mirasim 的调试端口（默认试 MIRAQUOTA_CDP_PORT、9333、9222）
  --feed-port <N>       feed 端口（默认在 ${FEED_LO}–${FEED_HI} 里取第一个空闲的）
  --channel-port <N>    mirachannel 端口（默认从进程命令行解析，回退 ${CHANNEL_DEFAULT}）
  --router-port <N>     直接指定挂着 /v1/limits 的路由端口，跳过发现
  --router-token <T>    /v1/limits 的会话令牌（等价 MIRAQUOTA_ROUTER_TOKEN）；
                        POSIX 上自动从会话进程环境读取，Windows 需手工给
  --widget <路径>       控件脚本（默认 ../widget/miraquota-widget.js）`);
  process.exit(0);
}

const CDP_PORTS = (() => {
  const explicit = opt('cdp-port', process.env.MIRAQUOTA_CDP_PORT);
  return explicit ? [Number(explicit)] : [9333, 9222];
})();

/* ---------------- 进程与端口发现 ---------------- */

const run = (cmd, args) => new Promise((resolve) => {
  execFile(cmd, args, { timeout: 5000, maxBuffer: 8 << 20, windowsHide: true },
    (err, stdout) => resolve(err && !stdout ? '' : String(stdout || '')));
});

/** Mirasim 的进程（pid 与命令行）。命令行里带 server.cjs 的才算。 */
async function mirasimProcesses() {
  if (process.platform === 'win32') {
    // Windows 的 tasklist 不给命令行，只有 CIM 查询能拿到 --port。
    const out = await run('powershell.exe', ['-NoProfile', '-Command',
      'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*server.cjs*" } |' +
      ' Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress']);
    if (!out.trim()) return [];
    let parsed;
    try { parsed = JSON.parse(out); } catch { return []; }
    const rows = Array.isArray(parsed) ? parsed : [parsed];
    return rows.map((r) => ({ pid: Number(r.ProcessId), cmd: String(r.CommandLine || '') }));
  }
  const out = await run('/bin/ps', ['-axo', 'pid=,command=']);
  return out.split('\n')
    .filter((l) => l.includes('server.cjs'))
    .map((l) => {
      const m = l.trim().match(/^(\d+)\s+(.*)$/);
      return m ? { pid: Number(m[1]), cmd: m[2] } : null;
    })
    .filter(Boolean);
}

/**
 * 指定 pid 集合持有的回环监听端口。
 * macOS 的 `lsof` 必须用 `-p` 限定进程：不带 `-p` 的 `-iTCP:<port>` 会全系统扫描，
 * 实测把调用卡住上百秒。
 */
async function listeningPorts(pids) {
  const byPid = new Map(pids.map((p) => [p, []]));
  const add = (pid, port) => { if (byPid.has(pid)) byPid.get(pid).push(port); };

  if (process.platform === 'darwin') {
    const out = await run('/usr/sbin/lsof',
      ['-nP', '-w', '-iTCP', '-sTCP:LISTEN', '-a', '-p', pids.join(','), '-Fpn']);
    let current = null;
    for (const line of out.split('\n')) {
      if (line.startsWith('p')) current = Number(line.slice(1));
      else if (line.startsWith('n127.0.0.1:') && current != null) {
        add(current, Number(line.slice('n127.0.0.1:'.length)));
      }
    }
  } else if (process.platform === 'win32') {
    // netstat 的 -o 给出 pid，无需管理员权限。
    const out = await run('netstat.exe', ['-ano', '-p', 'TCP']);
    for (const line of out.split('\n')) {
      const m = line.trim().match(/^TCP\s+127\.0\.0\.1:(\d+)\s+\S+\s+LISTENING\s+(\d+)$/i);
      if (m) add(Number(m[2]), Number(m[1]));
    }
  } else {
    const out = await run('ss', ['-Hltnp']);
    for (const line of out.split('\n')) {
      const port = line.match(/127\.0\.0\.1:(\d+)/);
      const pid = line.match(/pid=(\d+)/);
      if (port && pid) add(Number(pid[1]), Number(port[1]));
    }
  }
  return byPid;
}

const getJSON = async (url, ms = 2000, headers = undefined) => {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(ms), headers });
    return r.ok ? await r.json() : null;
  } catch { return null; }
};

/** mirachannel 端口：参数 → 命令行里的 --port → 惯用值 → 4970–4980 扫描。以 /api/health 校验。 */
async function discoverChannelPort(processes) {
  const verify = async (p) => {
    const j = await getJSON(`http://127.0.0.1:${p}/api/health`);
    return j && j.name === 'mirasim' ? p : null;
  };
  const explicit = Number(opt('channel-port', 0));
  if (explicit) return (await verify(explicit)) || explicit;

  const fromCmd = processes
    .map((p) => p.cmd.match(/--port[= ](\d+)/))
    .filter(Boolean).map((m) => Number(m[1]));
  for (const p of [...new Set([...fromCmd, CHANNEL_DEFAULT])]) {
    if (await verify(p)) return p;
  }
  for (let p = 4970; p <= 4980; p++) if (await verify(p)) return p;
  return null;
}

/**
 * 路由端口 → 会话令牌。早期版本对本机免认证，现行版本按普通 API 请求鉴权。
 * 令牌不落盘，只在 Mirasim 拉起的会话进程环境里：同一进程的 `ANTHROPIC_BASE_URL`
 * 指向哪个回环端口，`ANTHROPIC_AUTH_TOKEN` 就是那个端口的令牌。
 *
 * `ps` 必须用 `-U` 限定用户：不给选择符时只列「同用户且同控制终端」的进程，
 * 以服务方式常驻时没有控制终端，结果会是空的。Windows 的 CIM 不暴露进程环境，
 * 该平台只能用 `--router-token` / `MIRAQUOTA_ROUTER_TOKEN` 手工给。
 */
async function sessionTokens() {
  const explicit = opt('router-token', process.env.MIRAQUOTA_ROUTER_TOKEN);
  if (explicit) return { explicit: String(explicit), byPort: new Map() };
  if (process.platform === 'win32') return { explicit: null, byPort: new Map() };

  const user = process.env.USER || process.env.LOGNAME || '';
  const out = await run('/bin/ps', user ? ['eww', '-U', user, '-o', 'command=']
                                        : ['eww', '-o', 'command=']);
  const byPort = new Map();
  for (const line of out.split('\n')) {
    let port = null, token = null;
    // 逐个环境项精确匹配前缀：同一行还有 MIRASIM_PTY_PIN_ANTHROPIC_BASE_URL
    // 这类同名后缀的变量，子串匹配会配错。
    for (const field of line.split(' ')) {
      if (field.startsWith('ANTHROPIC_BASE_URL=http://127.0.0.1:')) {
        const m = field.match(/:(\d+)$/);
        if (m) port = Number(m[1]);
      } else if (field.startsWith('ANTHROPIC_AUTH_TOKEN=')) {
        token = field.slice('ANTHROPIC_AUTH_TOKEN='.length);
      }
    }
    if (port && token) byPort.set(port, token);
  }
  return { explicit: null, byPort };
}

/** `/v1/limits` 的请求头。令牌为空时不带，早期免认证的版本照常放行。 */
const limitsHeaders = (tokens, port) => {
  const token = tokens.explicit || tokens.byPort.get(port);
  return token ? { 'x-api-key': token } : undefined;
};

/**
 * 挂着 /v1/limits 的路由端口。
 * 限定「持有 mirachannel 端口的那个进程」的监听口：并行跑着开发实例时，
 * 别的实例可能是另一个账号，读到它的额度是错的。找不到归属就空手而归。
 */
async function discoverRouter(processes, channelPort) {
  const tokens = await sessionTokens();
  const explicit = Number(opt('router-port', 0));
  if (explicit) return { port: explicit, headers: limitsHeaders(tokens, explicit) };
  if (!processes.length) return null;

  const byPid = await listeningPorts(processes.map((p) => p.pid));
  let ports = null;
  for (const [, list] of byPid) {
    if (channelPort != null && list.includes(channelPort)) { ports = list; break; }
  }
  if (!ports) ports = [...byPid.values()].flat();
  // mirachannel 那个端口回的是首页 HTML，放到最后再试。
  const ordered = [...new Set(ports)].sort((a, b) =>
    (a === channelPort ? 1 : 0) - (b === channelPort ? 1 : 0));

  for (const p of ordered) {
    const headers = limitsHeaders(tokens, p);
    if (parseLimits(await getJSON(`http://127.0.0.1:${p}/v1/limits`, 2000, headers))) {
      return { port: p, headers };
    }
  }
  return null;
}

/* ---------------- 取数 ---------------- */

const num = (v) => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) ? n : null;
};

/** /v1/limits 的窗口。reset_at 可能是毫秒，归一化后仍越界的窗口丢弃。 */
function parseLimits(root) {
  if (!root || !Array.isArray(root.windows)) return null;
  const now = Date.now() / 1000;
  const windows = [];
  for (const w of root.windows) {
    const used = num(w.used), budget = num(w.budget);
    let reset = num(w.reset_at);
    if (used == null || budget == null || budget <= 0 || reset == null || !w.name) continue;
    if (reset > 1e11) reset /= 1000;
    if (reset < now - 86400 || reset > now + 30 * 86400) continue;
    windows.push({
      label: String(w.name),
      usedPercent: Math.min(100, used / budget * 100),
      points: { used, budget },
      resetAt: reset,
    });
  }
  if (!windows.length) return null;
  return {
    windows,
    suspended: !!root.suspended,
    unmetered: !!root.unmetered,
    degraded: !!root.degraded,
  };
}

/**
 * relay 帧退路：旧版 Mirasim 没有 /v1/limits 时用它，只拿到 0.1% 分辨率的百分比。
 * 这里只走常规键名。Swift 实现另有键名回退与有界深搜，移植时按需补。
 */
function relaySnapshot(channelPort) {
  return new Promise((resolve) => {
    if (channelPort == null) return resolve(null);
    let ws;
    const done = (v) => { try { ws && ws.close(); } catch { /* 已关 */ } resolve(v); };
    const timer = setTimeout(() => done(null), 4000);
    try {
      ws = new WebSocket(`ws://127.0.0.1:${channelPort}/mirachannel/ws`);
    } catch { clearTimeout(timer); return resolve(null); }

    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'hello', v: 1, client: { name: 'miraquota-provider' } }));
      ws.send(JSON.stringify({ type: 'host', payload: { type: 'getRelay' } }));
    });
    ws.addEventListener('error', () => { clearTimeout(timer); done(null); });
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(String(ev.data)); } catch { return; }
      const relay = msg && msg.payload && msg.payload.relay;
      const raw = relay && relay.usage && relay.usage.windows;
      if (!Array.isArray(raw)) return;
      clearTimeout(timer);

      // 刻度优先按「已用 + 剩余」之和判定：百分数刻度下该和恒为 100，小数刻度下恒为 1，
      // 与用量高低无关。缺 remainingPercent 时才退回量级判据（取值全部落在 (0,1] 才按
      // 小数换算），逐值判断区分不了「真实的 0.4%」与「小数的 0.4」；该判据在窗口
      // 滚动后的低用量期会判错，把 0.9% 放大成 90%。
      const totals = raw
        .map((w) => (num(w.usedPercent) != null && num(w.remainingPercent) != null
          ? num(w.usedPercent) + num(w.remainingPercent) : null))
        .filter((v) => v != null && v > 0.5);
      let scale;
      if (totals.length) {
        scale = Math.max(...totals) < 50 ? 100 : 1;
      } else {
        const seen = raw.map((w) => num(w.usedPercent)).filter((v) => v != null);
        for (const h of Array.isArray(relay.history) ? relay.history : []) {
          for (const k of ['fiveHour', 'sevenDay']) if (num(h[k]) != null) seen.push(num(h[k]));
        }
        scale = seen.length && seen.some((v) => v > 0) && seen.every((v) => v <= 1) ? 100 : 1;
      }

      const windows = [];
      for (const w of raw) {
        const pct = num(w.usedPercent);
        let reset = num(w.resetAt) ?? (Date.parse(w.resetAt || '') / 1000 || null);
        if (pct == null || !w.label) continue;
        if (reset != null && reset > 1e11) reset /= 1000;
        const value = pct * scale;
        if (value < 0 || value > 100.5) continue;
        windows.push({ label: String(w.label), usedPercent: Math.min(100, value), resetAt: reset });
      }
      done(windows.length ? { windows, relay } : null);
    });
  });
}

/* ---------------- 组装报告 ---------------- */

const STALE_AFTER = 90;
let last = null;                 // { at, windows, level, extra }

function pace(w, now) {
  const span = WINDOW_SECONDS[w.label];
  if (!span || w.resetAt == null) return {};
  const elapsed = Math.max(0, Math.min(span, span - (w.resetAt - now)));
  const pacePercent = elapsed / span * 100;
  return { pacePercent, paceDelta: w.usedPercent - pacePercent };
}

const LEVELS = {
  exact: '精确', live: '实时', stale: '已过期', local: '无数据',
};

async function collect() {
  const processes = await mirasimProcesses();
  const channelPort = await discoverChannelPort(processes);
  const router = await discoverRouter(processes, channelPort);

  const limits = router
    ? parseLimits(await getJSON(`http://127.0.0.1:${router.port}/v1/limits`, 2000, router.headers))
    : null;
  if (limits) {
    last = { at: Date.now() / 1000, windows: limits.windows, level: 'exact', extra: limits };
    return last;
  }
  const frame = await relaySnapshot(channelPort);
  if (frame) {
    last = { at: Date.now() / 1000, windows: frame.windows, level: 'live', extra: {} };
    return last;
  }
  return last;   // 取不到就保留上一次，供 stale 级显示
}

/** 契约 A 的载荷。只填有据可查的字段，其余一律省略——控件对缺字段是容忍的。 */
function payload() {
  const now = Date.now() / 1000;
  if (!last) {
    return {
      state: 'local', stateLabel: LEVELS.local, measured: false, capturedAt: now, windows: [],
      detail: '未取到 Mirasim 的额度接口：确认 Mirasim 正在运行。',
    };
  }
  const stale = now - last.at > STALE_AFTER;
  const level = stale ? 'stale' : last.level;
  const notice = last.extra && last.extra.suspended ? '账号被暂停，额度数字仅供参考'
    : last.extra && last.extra.unmetered ? '账号不计量，额度上限不适用'
    : last.extra && last.extra.degraded ? '上游降级运行中' : null;

  const out = {
    state: level,
    stateLabel: LEVELS[level],
    measured: level === 'exact' || level === 'live',
    capturedAt: last.at,
    detail: '参考 provider：只有额度点与百分比。美元金额、满额标定与速度卡需解析本机账本，'
          + '见 docs/ARCHITECTURE.md。',
    windows: last.windows.map((w) => ({
      label: w.label,
      usedPercent: w.usedPercent,
      inferred: false,
      confidence: 'none',
      ...(w.points ? { points: w.points } : {}),
      ...(w.resetAt != null ? { resetAt: w.resetAt } : {}),
      ...pace(w, now),
    })),
  };
  if (notice) out.accountNotice = notice;
  return out;
}

/* ---------------- 契约 A：feed ---------------- */

function feedToken() {
  try {
    const existing = readFileSync(TOKEN_FILE, 'utf8').trim();
    if (existing.length >= 16) return existing;
  } catch { /* 首次运行 */ }
  const fresh = randomBytes(16).toString('hex');
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(TOKEN_FILE, fresh, { mode: 0o600 });
  return fresh;
}

function startFeed(onQuit) {
  const token = feedToken();
  const server = createServer((req, res) => {
    // 控件带 ?t=<时间戳> 破缓存，按整串匹配会全落 404。
    const path = (req.url || '').split('?')[0];
    const head = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'X-MiraQuota-Token',
      'Cache-Control': 'no-store',
    };
    if (req.method === 'OPTIONS') { res.writeHead(204, head); return res.end(); }
    if (path === '/quota.json' && req.method === 'GET') {
      res.writeHead(200, { ...head, 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(payload()));
    }
    // 回环端口上任何网页都能发出不经预检的 GET 与裸 POST，故 /quit 必须验令牌。
    if (path === '/quit' && req.method === 'POST') {
      if (req.headers['x-miraquota-token'] !== token) {
        res.writeHead(403, head); return res.end();
      }
      res.writeHead(200, { ...head, 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
      return setTimeout(onQuit, 200);
    }
    res.writeHead(404, head);
    res.end();
  });

  return new Promise((resolve, reject) => {
    const explicit = Number(opt('feed-port', 0));
    let port = explicit || FEED_LO;
    server.on('error', (e) => {
      if (e.code === 'EADDRINUSE' && !explicit && port < FEED_HI) {
        server.listen(++port, '127.0.0.1');
      } else reject(e);
    });
    server.on('listening', () => resolve({ server, port }));
    server.listen(port, '127.0.0.1');   // 只绑回环
  });
}

/* ---------------- 契约 B：注入 ---------------- */

const widgetPath = opt('widget', join(HERE, '..', 'widget', 'miraquota-widget.js'));
const widgetSource = existsSync(widgetPath) ? readFileSync(widgetPath, 'utf8') : null;
const widgetVersion = widgetSource
  ? Number((widgetSource.match(/const VERSION = (\d+)/) || [])[1] || 0) : 0;

const registered = new Set();   // 已登记「新文档时执行」的 target，同一 target 只登记一次
let steady = 0, sweepTimer = null;

/** 一条 CDP 会话：发若干命令，返回指定 id 的回应。 */
function cdp(socketUrl, commands, wantId) {
  return new Promise((resolve) => {
    let ws;
    const done = (v) => { try { ws && ws.close(); } catch { /* 已关 */ } resolve(v); };
    const timer = setTimeout(() => done(null), 6000);
    try { ws = new WebSocket(socketUrl); } catch { clearTimeout(timer); return resolve(null); }
    ws.addEventListener('error', () => { clearTimeout(timer); done(null); });
    ws.addEventListener('open', () => { for (const c of commands) ws.send(JSON.stringify(c)); });
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(String(ev.data)); } catch { return; }
      // 必须等到目标那一条的回应：只等任意一帧会拿到前一条命令的回执，
      // 随后关连接可能在脚本真正执行前就断开，页面就此空着。
      if (msg.id === wantId) { clearTimeout(timer); done(msg); }
    });
  });
}

async function sweep(feedPort) {
  if (!widgetSource) return;
  let targets = null, cdpPort = null;
  for (const p of CDP_PORTS) {
    const list = await getJSON(`http://127.0.0.1:${p}/json`);
    if (Array.isArray(list)) { targets = list; cdpPort = p; break; }
  }
  if (!targets) {
    steady = 0;
    return reschedule(feedPort, SWEEP_MS, `找不到调试端口（试过 ${CDP_PORTS.join('、')}）`);
  }

  const pages = targets.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);
  const prelude = `window.__MIRAQUOTA_FEED__="http://127.0.0.1:${feedPort}";\n`;
  const script = prelude + widgetSource;
  let hits = 0, injected = 0;

  for (const t of pages) {
    // 判在场靠探针不靠 target id：页面刷新后 id 不变，而控件已经没了。
    const probe = await cdp(t.webSocketDebuggerUrl, [{
      id: 1, method: 'Runtime.evaluate',
      params: { expression: 'window.__miraquotaVersion||0', returnByValue: true },
    }], 1);
    const seen = Number(probe?.result?.result?.value || 0);
    if (seen >= widgetVersion) { hits++; continue; }

    const commands = [{ id: 1, method: 'Page.enable' }];
    if (!registered.has(t.id)) {
      // 每 target 只登记一次，否则页面一刷新同一段脚本会跑几十遍。
      commands.push({ id: 2, method: 'Page.addScriptToEvaluateOnNewDocument',
                      params: { source: script } });
    }
    commands.push({ id: 3, method: 'Runtime.evaluate',
                    params: { expression: script, awaitPromise: false, returnByValue: false } });
    const reply = await cdp(t.webSocketDebuggerUrl, commands, 3);
    if (reply && !reply.result?.exceptionDetails) {
      registered.add(t.id);
      injected++; hits++;
    }
  }

  steady = injected === 0 && hits === pages.length && pages.length > 0 ? steady + 1 : 0;
  const wait = steady >= STEADY_ROUNDS ? SWEEP_IDLE_MS : SWEEP_MS;
  reschedule(feedPort, wait,
    `cdp ${cdpPort} · 页面 ${pages.length} · 已带控件 ${hits} · 本轮注入 ${injected}`);
}

function reschedule(feedPort, wait, note) {
  log(`注入 ${note}`);
  sweepTimer = setTimeout(() => sweep(feedPort), wait);
}

/* ---------------- 主流程 ---------------- */

const log = (m) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${m}`);

const fmtReset = (t) => {
  if (t == null) return '无重置';
  const left = Math.max(0, t - Date.now() / 1000);
  return left >= 86400 ? `重置 ${(left / 86400).toFixed(1)} 天`
    : `重置 ${String(Math.floor(left / 3600)).padStart(2, '0')}:${String(Math.floor(left % 3600 / 60)).padStart(2, '0')}`;
};

function printSnapshot(p) {
  console.log(`通道 ${p.stateLabel}${p.accountNotice ? ' · ' + p.accountNotice : ''}`);
  if (!p.windows.length) return console.log('无窗口');
  for (const w of p.windows) {
    const pts = w.points ? `  ${Math.round(w.points.used)}/${Math.round(w.points.budget)} 点` : '';
    const pd = w.paceDelta == null ? ''
      : `  均速偏离 ${w.paceDelta >= 0 ? '+' : ''}${w.paceDelta.toFixed(1)}%`;
    console.log(`${w.label.padEnd(9)} ${w.usedPercent.toFixed(1).padStart(5)}%${pts}${pd}  ${fmtReset(w.resetAt)}`);
  }
}

if (flag('once')) {
  await collect();
  printSnapshot(payload());
  process.exit(last ? 0 : 1);
}

const { server, port: feedPort } = await startFeed(() => shutdown(0));
log(`feed http://127.0.0.1:${feedPort}/quota.json`);
if (widgetSource) log(`控件 v${widgetVersion} ${widgetPath}`);
else log(`控件脚本不存在，注入跳过：${widgetPath}`);

await collect();
printSnapshot(payload());
const pollTimer = setInterval(() => collect().catch(() => {}), POLL_MS);
if (!flag('no-inject')) sweep(feedPort).catch((e) => log('注入异常 ' + e.message));

function shutdown(code) {
  clearInterval(pollTimer);
  if (sweepTimer) clearTimeout(sweepTimer);
  server.close();
  process.exit(code);
}
process.on('SIGINT', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));
