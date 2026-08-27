/*
 * MiraQuota 客户端控件
 *
 * 由 MiraQuota 经 CDP 注入 Mirasim 的渲染进程（不改 Mirasim 的任何文件）。
 * 数据来自本机回环接口 window.__MIRAQUOTA_FEED__ + "/quota.json"，
 * 额度点、美元、速度都在 Swift 侧算好，这里只负责画。
 *
 * 标题栏胶囊 + 点击展开的详情层。位置可拖动，存 localStorage。
 *
 * v13 起骨架只建一次，更新只改文本与宽度：整树重建会让 CSS 过渡失去起点
 * （新节点直接以终值挂载），也会每秒清掉 hover 与选区。
 *
 * v14 去掉「双击回默认位」：该手势与「点胶囊开合」共用同一目标，快速开合面板时会误触发，
 * 代价是丢掉拖好的位置且无法撤销。位置已有视口夹取兜底，无须复位入口。
 *
 * v19 布局与动画一轮打磨：页脚由顿点长串改为键值三行；展开时卡片与进度条错峰落位
 * （序号写在卡片的 --i 上，须走 setProperty——`style['--i']=x` 静默无效）；
 * 均速游标改为出条上下各一像素，压在实色段上也分得清；
 * 有请求在途时胶囊上的点跟着跳，收起状态下也看得出正在生成。
 *
 * v20 满额不可用时主行改用点数：兜底满额来自本机账本反推的每点美元，账本失真会把满额
 * 同倍放大，而卡面只有一个 `~` 前缀。Swift 侧判出账本与点数不自洽即不再给 fullUSD，
 * 此时把账本支出抬到主行同样不可信，故主行取点数，账本留在副行。
 *
 * v15–v17 加标题栏吸附：宿主标题栏右侧本就排着自己的控件，控件贴右上角会压在上面。
 * 拖到标题栏空位附近即吸附（吸附位取「不与宿主控件重叠的最右一段空位」），
 * 之后随宿主布局变化（窗口缩放、标签增减）一起走。拖离即解除。
 * 竖向位置按宿主底色的连续段居中，不按 header 元素高度——两者差 6px，
 * 按元素高度算出来的位置在眼睛看来偏高。
 */
(() => {
  'use strict';
  const VERSION = 20;
  if (window.__miraquotaWidget) {
    // 接管而非让位：持久注册的旧脚本每次导航都先执行、先占坑，
    // 让位式守卫会把后注册的新版本永远挡在门外。
    if ((window.__miraquotaVersion || 0) >= VERSION) return;
    try { window.__miraquotaTeardown && window.__miraquotaTeardown(); } catch (e) { /* 旧版无此钩子 */ }
  }
  // 热替换时先让旧实例自我清场：否则旧实例残留的 MutationObserver 会与本实例
  // 互抢同名宿主，形成微任务风暴把渲染进程主线程打满（v6 实测卡死整页）。
  try { window.__miraquotaTeardown && window.__miraquotaTeardown(); } catch (e) { /* 已清场 */ }
  window.__miraquotaWidget = true;
  window.__miraquotaVersion = VERSION;

  // 烤入的地址只是首选提示：持久注入的脚本带着注入时刻的端口，
  // MiraQuota 重启换绑后失效，届时在固定区间里重找（见 rediscover）。
  let feed = (window.__MIRAQUOTA_FEED__ || 'http://127.0.0.1:4988').replace(/\/$/, '');
  const PORT_LO = 4988, PORT_HI = 4995;
  const POLL_MS = 5000;
  const POLL_MS_LIVE = 2000;   // 有请求在途时轮询更勤，让"生成中"跟得上
  const STALE_S = 90;          // 采集时刻早于此即认为数据已旧，胶囊降饱和
  const LS = { top: 'mq.top', right: 'mq.right', dock: 'mq.dock' };
  const HOME = { top: 6, right: 12 };
  /// 标题栏带高度的兜底值与吸附判定阈值（CSS 像素）。
  /// 真实带高按宿主底色的连续段实测（见 barBand）：Mirasim 的 header 元素是 28px，
  /// 其下还有约 6px 同色区域，眼睛看到的是一整条 34px 的深色带，
  /// 按 28 居中会偏高 3px。
  /// 两个轴分别定阈：竖向要贴着标题栏，横向给一个较宽的窗口；
  /// 另外只要落位会压住宿主自己的控件，一律算命中吸附。
  const BAR_FALLBACK = 28;
  const SNAP_Y = 16;
  const SNAP_X = 140;

  // localStorage 在不透明源（data: 页面、部分 file:// 场景）上会直接抛异常，
  // 一次未捕获就会让整个控件停在半成品状态，故一律走这层，失败退回内存。
  const store = {
    mem: {},
    get(k) {
      try {
        const v = localStorage.getItem(k);
        if (v != null) return v;
      } catch (e) { /* 不透明源 */ }
      return this.mem[k];
    },
    set(k, v) {
      this.mem[k] = v;
      try { localStorage.setItem(k, v); } catch (e) { /* 不透明源 */ }
    },
  };

  const state = { data: null, open: false, at: 0, err: null, quitAsked: false, quitSent: false };
  // 排查用把手：注入环境里没有控制台，出问题时能从外部读到状态。
  window.__miraquotaState = state;

  /* ---------------- 取数 ---------------- */

  let probing = false;
  async function rediscover() {
    if (probing) return;
    probing = true;
    try {
      for (let p = PORT_LO; p <= PORT_HI; p++) {
        const base = 'http://127.0.0.1:' + p;
        if (base === feed) continue;
        try {
          const r = await fetch(base + '/quota.json?t=' + Date.now(), { cache: 'no-store' });
          if (!r.ok) continue;
          const j = await r.json();
          if (j && Array.isArray(j.windows)) { feed = base; return; }
        } catch (e) { /* 下一个端口 */ }
      }
    } finally { probing = false; }
  }

  async function poll() {
    try {
      const r = await fetch(feed + '/quota.json?t=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const j = await r.json();
      if (j && Array.isArray(j.windows)) {
        state.data = j;
        state.at = Date.now();
        state.err = null;
      }
    } catch (e) {
      state.err = String(e.message || e);
      await rediscover();
    }
    paint();
  }

  /* ---------------- 格式 ---------------- */

  const usd = (v) => v == null ? '—'
    : v >= 1000 ? '$' + Math.round(v).toLocaleString()
    : v >= 100 ? '$' + v.toFixed(0) : '$' + v.toFixed(1);

  const pct = (v) => v == null ? '—' : v.toFixed(1) + '%';

  // 额度点用紧凑写法：六位数字并排会把卡片底行挤满，量级本身够读。
  const kilo = (n) => n >= 10000 ? (n / 1000).toFixed(n >= 100000 ? 0 : 1) + 'k'
    : String(Math.round(n));

  // 时间单位统一为「天 / 小时 / 分钟」，数字与汉字之间留一个空格。
  function countdown(sec) {
    if (sec == null) return '';
    if (sec <= 0) return '即将重置';
    if (sec >= 86400) {
      const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600);
      return h > 0 ? `重置 ${d} 天 ${h} 小时` : `重置 ${d} 天`;
    }
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = Math.floor(sec % 60);
    const mm = String(m).padStart(2, '0'), ss = String(s).padStart(2, '0');
    // 小时位一律保留：「重置 13:06」会被读成时刻，「重置 0:13:06」不会。
    return `重置 ${h}:${mm}:${ss}`;
  }

  const clock = (t) => {
    const d = new Date(t * 1000);
    return [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((x) => String(x).padStart(2, '0')).join(':');
  };

  const winTitle = (label) => label === '5h' ? '5 小时' : label === '7d' ? '7 天'
    : label === '7d_fable' ? '7 天 · Fable' : label;

  // 胶囊上的窗口简称，长度要压住。
  const winShort = (label) => label === '7d_fable' ? '7d·F' : label;

  // 模型显示名去掉快照日期后缀，避免长名折行撑高速度卡。
  const shortModel = (m) => String(m || '').replace(/-\d{8}$/, '');

  // 打满外推的时长短格式。
  function fmtDur(sec) {
    if (sec < 5400) return Math.round(sec / 60) + ' 分钟';
    if (sec < 86400) return (sec / 3600).toFixed(1) + ' 小时';
    return (sec / 86400).toFixed(1) + ' 天';
  }

  // 样本新鲜度。速度不动多半是没有新请求，把这件事显式说出来。
  function ago(t) {
    const s = Math.max(0, Date.now() / 1000 - t);
    if (s < 90) return Math.round(s) + ' 秒前';
    if (s < 5400) return Math.round(s / 60) + ' 分钟前';
    if (s < 172800) return Math.round(s / 3600) + ' 小时前';
    return Math.round(s / 86400) + ' 天前';
  }

  /* ---------------- 骨架 ---------------- */

  const host = document.createElement('div');
  host.id = 'miraquota-widget';
  const sh = host.attachShadow({ mode: 'open' });
  sh.innerHTML = `
  <style>
  :host { all: initial; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  .root {
    /* 控件跟着宿主跑，宿主在哪个平台就用哪一档系统字：Windows 上前两项都不存在，
       落到 Segoe UI 与微软雅黑；只写苹方会让中文退到通用 sans-serif。 */
    font-family: -apple-system, "SF Pro Text", "Segoe UI", "PingFang SC",
      "Microsoft YaHei", "Noto Sans CJK SC", sans-serif;
    -webkit-font-smoothing: antialiased;
    --ink: rgba(255,255,255,.94); --ink2: rgba(255,255,255,.58); --ink3: rgba(255,255,255,.36);
    --bg: rgba(255,255,255,.08); --bgh: rgba(255,255,255,.15); --bd: rgba(255,255,255,.1);
    --pop: rgba(28,28,31,.62); --card: rgba(255,255,255,.055); --cardbd: rgba(255,255,255,.075);
    --cardhl: rgba(255,255,255,.05); --cardhi: rgba(255,255,255,.085);
    --track: rgba(255,255,255,.12); --notch: rgba(0,0,0,.35);
    --ok: #4cd471; --okbg: rgba(76,212,113,.14);
    --live: #5fd8c4;
    --accent: #7aa2ff; --accent2: #a8c3ff; --accentbg: rgba(122,162,255,.16);
    --accentglow: rgba(122,162,255,.4);
    --warn: #ffb04d; --warn2: #ffce90; --warnbg: rgba(255,176,77,.15);
    --warnglow: rgba(255,176,77,.35);
    --bad: #ff6f6f; --bad2: #ffa5a5; --badbg: rgba(255,111,111,.16);
    --badglow: rgba(255,111,111,.4);
    --shadow: 0 0 0 .5px rgba(0,0,0,.5), 0 24px 60px rgba(0,0,0,.55), 0 4px 14px rgba(0,0,0,.3);
    --pillshadow: inset 0 .5px 0 rgba(255,255,255,.09), 0 2px 8px rgba(0,0,0,.22);
    --ease: cubic-bezier(.32,.72,0,1);
  }
  .root.light {
    --ink: rgba(0,0,0,.88); --ink2: rgba(0,0,0,.54); --ink3: rgba(0,0,0,.36);
    --bg: rgba(0,0,0,.05); --bgh: rgba(0,0,0,.1); --bd: rgba(0,0,0,.09);
    --pop: rgba(250,250,250,.7); --card: rgba(0,0,0,.035); --cardbd: rgba(0,0,0,.055);
    --cardhl: transparent; --cardhi: rgba(0,0,0,.06);
    --track: rgba(0,0,0,.09); --notch: rgba(255,255,255,.75);
    --ok: #1e9e50; --okbg: rgba(30,158,80,.11);
    --live: #12897c;
    --accent: #2f6bff; --accent2: #6d99ff; --accentbg: rgba(47,107,255,.1);
    --accentglow: rgba(47,107,255,.22);
    --warn: #b26a05; --warn2: #d99a3e; --warnbg: rgba(178,106,5,.11);
    --warnglow: rgba(178,106,5,.2);
    --bad: #d03333; --bad2: #e57070; --badbg: rgba(208,51,51,.1);
    --badglow: rgba(208,51,51,.22);
    --shadow: 0 0 0 .5px rgba(0,0,0,.08), 0 24px 60px rgba(0,0,0,.16), 0 4px 14px rgba(0,0,0,.08);
    --pillshadow: 0 1px 5px rgba(0,0,0,.1);
  }
  /* 系统设了「减弱动态效果」时一律直接换值，不做过渡与脉冲。 */
  .root.rm *, .root.rm { transition: none !important; animation: none !important; }

  .pill {
    display: flex; align-items: center; gap: 7px; height: 22px; padding: 0 9px;
    border-radius: 11px; background: var(--bg); border: .5px solid var(--bd);
    color: var(--ink); font-size: 11px; line-height: 1; cursor: grab;
    user-select: none; -webkit-user-select: none;
    font-variant-numeric: tabular-nums; backdrop-filter: blur(18px) saturate(140%);
    box-shadow: var(--pillshadow);
    transition: background .15s ease, transform .12s ease, opacity .2s ease, filter .2s ease;
  }
  .pill:hover { background: var(--bgh); }
  .pill:active { transform: scale(.97); }
  .root.dragging .pill { cursor: grabbing; transform: none; }
  /* 吸附命中时给一圈提示，松手才落定。 */
  .pill.snap { box-shadow: var(--pillshadow), 0 0 0 1.5px var(--accent); }
  /* 数据已旧：数字仍在，但读的人应当看出它不是当下值。 */
  .root.stale .pill { opacity: .6; filter: saturate(.35); }
  .seg { display: flex; align-items: center; gap: 5px; }
  .dot { width: 6px; height: 6px; border-radius: 3px; background: var(--ink3); flex: none;
    transition: background .2s ease; }
  .dot.exact { background: var(--ok); }
  .dot.live { background: var(--live); }
  .dot.stale { background: var(--warn); }
  .dot.reckoned { background: var(--warn); }
  .dot.mismatch { background: var(--bad); }
  /* 有请求在途：胶囊收起时也能看出正在生成，不必展开。 */
  .dot.busy { animation: mqPulse 1.2s ease-in-out infinite; }
  .sep { width: .5px; height: 11px; background: var(--bd); }
  .lb { color: var(--ink2); font-weight: 600; }
  /* 纯色文字盖在磨砂材质上，色相接近背景时几乎读不出来，垫一层同色底色。 */
  .v.warn { color: var(--warn); background: var(--warnbg); border-radius: 5px; padding: 0 3px; }
  .v.bad { color: var(--bad); background: var(--badbg); border-radius: 5px; padding: 0 3px; }
  /* 胶囊上的金额取次级色而非三级：它是收起状态下唯一的绝对量，压得太暗就读不出。 */
  .u { color: var(--ink2); }

  .pop {
    position: fixed; width: 306px; border-radius: 16px; padding: 12px; z-index: 2147483646;
    max-height: calc(100vh - 16px); overflow-y: auto; overscroll-behavior: contain;
    background: var(--pop); border: .5px solid var(--bd); box-shadow: var(--shadow);
    color: var(--ink); font-size: 12px; backdrop-filter: blur(56px) saturate(180%);
    opacity: 0; transform: scale(.965) translateY(-6px); transform-origin: top right;
    pointer-events: none; transition: opacity .18s ease, transform .26s var(--ease);
    user-select: text; -webkit-user-select: text;
  }
  .pop.on { opacity: 1; transform: none; pointer-events: auto; }
  .pop::-webkit-scrollbar { width: 6px; }
  .pop::-webkit-scrollbar-thumb { background: var(--bd); border-radius: 3px; }
  .hd { display: flex; align-items: center; gap: 8px; margin-bottom: 9px; }
  .hd .t { font-size: 13px; font-weight: 700; letter-spacing: .02em; }
  .chip { margin-left: auto; display: flex; align-items: center; gap: 5px; padding: 2.5px 8px;
    border-radius: 9px; background: var(--bg); color: var(--ink2); font-size: 10px; font-weight: 500;
    transition: background .2s ease, color .2s ease; }
  .chip.ok { background: var(--okbg); color: var(--ok); }
  .chip.warn { background: var(--warnbg); color: var(--warn); }
  .chip .dot { width: 5px; height: 5px; }
  .banner { padding: 7px 9px; border-radius: 8px; background: var(--bg); color: var(--ink2);
    font-size: 10.5px; margin-bottom: 8px; line-height: 1.45; }
  /* 展开时逐张落位。--i 由 drawCards 写在卡片上，错峰四十余毫秒，
     视线跟着从上往下走一遍，比整层同时出现更容易读出顺序。 */
  @keyframes mqCardIn { from { opacity: 0; transform: translateY(7px); } }
  .pop.on .card { animation: mqCardIn .34s var(--ease) backwards;
    animation-delay: calc(var(--i, 0) * 45ms); }
  .card { padding: 9px 10px; border-radius: 11px; background: var(--card);
    transition: background .18s ease;
    border: .5px solid var(--cardbd); margin-bottom: 6px;
    box-shadow: inset 0 .5px 0 var(--cardhl); }
  .card:hover { background: var(--cardhi); }
  /* 主窗口（5h）在三张卡里权重最高，金额字号与底色都略强一档。 */
  .card.primary { background: var(--cardhi); }
  .card.primary:hover { background: var(--bgh); }
  .card.primary .amt b { font-size: 16px; }
  /* 速度卡与上面三张窗口卡是两类东西，间距拉开一档，不连成一片。 */
  #speedbox { display: block; margin-top: 3px; }
  /* 标签定宽：三个窗口名长度不同，不定宽金额会各自起在不同位置。 */
  .crow { display: grid; grid-template-columns: 74px 1fr auto; align-items: baseline; gap: 5px; }
  .crow .wl { font-size: 11px; color: var(--ink2); font-weight: 550; white-space: nowrap;
    overflow: hidden; text-overflow: ellipsis; }
  .crow .amt { font-size: 13.5px; font-weight: 700; letter-spacing: -.01em;
    font-variant-numeric: tabular-nums; white-space: nowrap; }
  .crow .amt i { font-style: normal; font-size: 10px; font-weight: 500; color: var(--ink3); }
  .crow .pc { justify-self: end; font-size: 11px; font-weight: 650; padding: 2px 7px;
    font-variant-numeric: tabular-nums; letter-spacing: -.01em;
    border-radius: 8px; font-variant-numeric: tabular-nums;
    background: var(--accentbg); color: var(--accent); transition: background .2s ease, color .2s ease; }
  .pc.warn { background: var(--warnbg); color: var(--warn); }
  .pc.bad { background: var(--badbg); color: var(--bad); }
  @keyframes mqBarIn { from { transform: scaleX(0); } }
  /* 与卡片同一节奏，稍晚一点：卡片先落位，条再长出来。 */
  .pop.on .bar .fill { animation: mqBarIn .55s var(--ease) backwards;
    animation-delay: calc(var(--i, 0) * 45ms + 70ms); transform-origin: left center; }
  .bar { position: relative; height: 6px; border-radius: 3px; background: var(--track);
    box-shadow: inset 0 .5px 1px rgba(0,0,0,.14);
    margin-top: 6px; overflow: hidden; }
  .bar .fill { position: absolute; inset: 0 auto 0 0; border-radius: 3px; min-width: 3px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    box-shadow: 0 0 8px var(--accentglow);
    transition: width .5s var(--ease), background .3s ease, box-shadow .3s ease; }
  .fill.warn { background: linear-gradient(90deg, var(--warn), var(--warn2));
    box-shadow: 0 0 8px var(--warnglow); }
  .fill.bad { background: linear-gradient(90deg, var(--bad), var(--bad2));
    box-shadow: 0 0 8px var(--badglow); }
  /* 均速游标：不跨出轨道，低用量时不再与填充叠成十字。 */
  /* 线用前景色、外圈用底色：两个主题下都是「深线浅圈」或「浅线深圈」，不会只剩描边。 */
  .bar .pace { position: absolute; top: -1px; bottom: -1px; width: 2px; border-radius: 1px;
    background: var(--ink2); box-shadow: 0 0 0 1px var(--notch);
    transition: left .5s var(--ease); }
  .foot { display: flex; margin-top: 5px; font-size: 9.5px; color: var(--ink2);
    white-space: nowrap; font-variant-numeric: tabular-nums; }
  .foot .eta { color: var(--ink2); margin-left: 4px; }
  .foot .eta.soon { color: var(--warn); background: var(--warnbg); border-radius: 5px; padding: 0 4px; margin-left: 2px; }
  .foot .r { margin-left: auto; padding-left: 8px; color: var(--ink3); }
  .sub { margin-top: 3px; font-size: 9px; color: var(--ink3); white-space: nowrap;
    font-variant-numeric: tabular-nums; }
  /* 模型名与数值列定宽：宽度随内容浮动时，偏离标与时刻会逐行错开。
     数值列可压到下限后省略，不折行——折行会撑高行高并推歪右侧两列。 */
  .sp { display: flex; align-items: center; gap: 6px; font-size: 10px; margin-top: 5px; }
  .sp .m { width: 58px; flex: none; color: var(--ink); font-weight: 600;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sp .v { min-width: 100px; font-variant-numeric: tabular-nums; color: var(--ink2);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sp .dr { flex: none; font-variant-numeric: tabular-nums; }
  .sp .dr.slow { color: var(--warn); background: var(--warnbg); border-radius: 5px; padding: 0 4px; }
  .sp .dr.fast { color: var(--ok); background: var(--okbg); border-radius: 5px; padding: 0 4px; }
  .sp .n { margin-left: auto; flex: none; white-space: nowrap; color: var(--ink3);
    font-size: 9.5px; font-variant-numeric: tabular-nums; }
  .live { display: inline-flex; align-items: center; gap: 4px; font-size: 9.5px; color: var(--ok); font-weight: 600;
    background: var(--okbg); border-radius: 8px; padding: 2px 7px; }
  .pulse { width: 6px; height: 6px; border-radius: 3px; background: var(--ok); animation: mqPulse 1.2s ease-in-out infinite; }
  @keyframes mqPulse { 0%,100% { opacity: 1; transform: scale(1); } 50% { opacity: .3; transform: scale(.7); } }
  .meta { font-size: 9.5px; color: var(--ink3); line-height: 1.6; }
  /* 三行键值。原先是一长串顿点连缀，键与值混在一起，扫不出哪段是哪段。 */
  .mrow { display: grid; grid-template-columns: 30px 1fr; gap: 6px; align-items: baseline; }
  .mrow .k { color: var(--ink3); opacity: .8; }
  .mrow .mv { color: var(--ink2); font-variant-numeric: tabular-nums;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .hair { height: .5px; background: var(--bd); margin: 9px 0 7px; }
  .bottom { display: flex; align-items: center; margin-top: 5px; font-size: 9.5px; color: var(--ink3);
    font-variant-numeric: tabular-nums; }
  .quit { margin-left: auto; color: var(--ink2); cursor: default; padding: 2.5px 9px;
    border-radius: 7px; border: .5px solid var(--bd); user-select: none; -webkit-user-select: none;
    transition: background .12s ease, color .12s ease, border-color .12s ease; }
  .quit:hover { background: var(--bgh); color: var(--ink); }
  .quit.armed { color: var(--warn); border-color: var(--warn); background: var(--warnbg); }
  [hidden] { display: none !important; }
  </style>
  <div class="root">
    <div class="pill" id="pill">
      <span class="dot" id="dot"></span>
      <span class="seg" id="seg1"><span class="lb" id="lb1">5h</span><span class="v" id="v1">—</span><span class="u" id="u1"></span></span>
      <span class="sep" id="sep" hidden></span>
      <span class="seg" id="seg2" hidden><span class="lb" id="lb2">7d</span><span class="v" id="v2"></span></span>
    </div>
    <div class="pop" id="pop">
      <div class="hd">
        <span class="t">额度</span>
        <span class="chip" id="chip"><span class="dot" id="cdot"></span><span id="clabel">连接中</span></span>
      </div>
      <div id="banners"></div>
      <div id="cards"></div>
      <div id="speedbox"></div>
      <div class="hair"></div>
      <div class="meta">
        <div class="mrow" id="rowFull"><span class="k">满额</span><span class="mv" id="metaFull"></span></div>
        <div class="mrow" id="rowLedger"><span class="k">账本</span><span class="mv" id="metaLedger"></span></div>
        <div class="mrow" id="rowLine"><span class="k">线路</span><span class="mv" id="metaLine"></span></div>
      </div>
      <div class="bottom"><span id="stamp"></span><span class="quit" id="quit">退出</span></div>
    </div>
  </div>`;

  const $ = (id) => sh.getElementById(id);
  const root = sh.querySelector('.root');
  const pill = $('pill'), pop = $('pop');
  const els = {
    dot: $('dot'), lb1: $('lb1'), v1: $('v1'), u1: $('u1'),
    sep: $('sep'), seg2: $('seg2'), lb2: $('lb2'), v2: $('v2'),
    chip: $('chip'), cdot: $('cdot'), clabel: $('clabel'),
    banners: $('banners'), cards: $('cards'), speedbox: $('speedbox'),
    rowFull: $('rowFull'), metaFull: $('metaFull'),
    rowLedger: $('rowLedger'), metaLedger: $('metaLedger'),
    rowLine: $('rowLine'), metaLine: $('metaLine'),
    stamp: $('stamp'), quit: $('quit'),
  };

  // 供下一个版本热替换时调用：断开 observer 与定时器后再摘宿主，避免上述互抢。
  const cleanup = [];
  window.__miraquotaTeardown = () => {
    for (const fn of cleanup) { try { fn(); } catch (e) { /* 尽力而为 */ } }
    delete window.__miraquotaWidget;
    delete window.__miraquotaTeardown;
    host.remove();
  };

  /* ---------------- 增量更新的小工具 ---------------- */

  const reduced = () => root.classList.contains('rm');

  // 值变了就淡入一次。整树重建时这类过渡都没有起点，故必须配合骨架复用。
  function flash(el) {
    if (!el || reduced() || !el.animate) return;
    try { el.animate([{ opacity: .35 }, { opacity: 1 }], { duration: 420, easing: 'ease-out' }); }
    catch (e) { /* 老引擎无 Web Animations */ }
  }

  function setText(el, s) {
    if (!el) return;
    const next = s == null ? '' : String(s);
    if (el.__v === next) return;
    const first = el.__v === undefined;
    el.__v = next;
    el.textContent = next;
    if (!first) flash(el);
  }

  // 倒计时、龄期一类每秒都在走的字段：改值但不淡入，否则整层每秒闪一次。
  function setTick(el, s) {
    if (!el) return;
    const next = s == null ? '' : String(s);
    if (el.__v === next) return;
    el.__v = next;
    el.textContent = next;
  }

  function setTone(el, base, tone) {
    if (!el) return;
    const next = tone ? base + ' ' + tone : base;
    if (el.className === next) return;
    el.className = next;
  }

  function setHidden(el, hidden) {
    if (el && el.hidden !== hidden) el.hidden = hidden;
  }

  function setStyle(el, key, value) {
    if (el && el.style[key] !== value) el.style[key] = value;
  }

  /// 自定义属性（--x）不在 CSSStyleDeclaration 的具名属性里，赋值不会生效，也不报错。
  function setVar(el, key, value) {
    if (el && el.style.getPropertyValue(key) !== value) el.style.setProperty(key, value);
  }

  function toneOf(p) { return p >= 95 ? 'bad' : p >= 80 ? 'warn' : ''; }

  /* ---------------- 落位与拖动 ---------------- */

  const num = (k, fallback) => {
    const v = Number(store.get(k));
    return Number.isFinite(v) ? v : fallback;
  };
  const saved = () => ({ top: num(LS.top, HOME.top), right: num(LS.right, HOME.right) });

  /* ---------------- 标题栏吸附 ---------------- */

  // 判定标题栏上某点是否被宿主自己的控件占着。只看最上层的非宿主元素：
  // 命中按钮/图标一类即算占位，容器 div 上的空白区不算。
  function occupied(x, y) {
    let stack;
    try { stack = document.elementsFromPoint(x, y); } catch (e) { return true; }
    for (const el of stack) {
      if (el === host || host.contains(el)) continue;
      if (el === document.documentElement || el === document.body) continue;
      try {
        if (el.closest('button,a,input,select,textarea,svg,img,canvas,[role="button"],[role="tab"]')) return true;
      } catch (e) { /* closest 不可用时按未占位处理 */ }
      for (const n of el.childNodes) {
        if (n.nodeType === 3 && n.textContent.trim()) return true;
      }
      return false;
    }
    return false;
  }

  /// 某点处生效的背景色：自身透明就往上找，直到找到不透明的祖先。
  function effBg(el) {
    for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
      const c = getComputedStyle(n).backgroundColor;
      if (c && c !== 'transparent' && !/,\s*0\s*\)$/.test(c)) return c;
    }
    try { return getComputedStyle(document.documentElement).backgroundColor || ''; }
    catch (e) { return ''; }
  }

  /// 视觉上的标题栏带高度：自顶往下，底色与 y=1 处相同的连续段有多高。
  /// 不按元素高度取值——宿主 header 是 28px，其下还有同色区域，
  /// 眼睛看到的是一整条深色带，按元素高度居中就偏高。
  function barBand(x) {
    let el = document.elementFromPoint(x, 1);
    if (!el || host.contains(el)) return BAR_FALLBACK;
    const base = effBg(el);
    if (!base) return BAR_FALLBACK;
    let y = 2;
    for (; y <= 120; y += 1) {
      el = document.elementFromPoint(x, y);
      if (!el || host.contains(el)) break;
      if (effBg(el) !== base) break;
    }
    return y >= 16 ? y - 1 : BAR_FALLBACK;
  }

  /// 占位采样。命中测试有代价，故一次扫完存下来：
  /// 拖动过程中宿主布局不变，整段拖动共用同一份。
  const BAND_STEP = 6;
  const bandIndex = (x) => Math.max(0, Math.round((x - 2) / BAND_STEP));

  function sampleRow(y) {
    const busy = [];
    for (let x = 2; x < window.innerWidth; x += BAND_STEP) busy.push(occupied(x, y) ? 1 : 0);
    return busy;
  }

  /// 连续空白段，从左到右。
  function runsOf(busy, need, width) {
    const out = [];
    let from = null;
    for (let i = 0; i < busy.length; i++) {
      const x = 2 + i * BAND_STEP;
      if (!busy[i]) { if (from == null) from = x; continue; }
      if (from != null && x - from >= need) out.push({ from, to: x - BAND_STEP });
      from = null;
    }
    if (from != null && width - 4 - from >= need) out.push({ from, to: width - 4 });
    return out;
  }

  /// 扫一遍标题栏：先在兜底中线上找空段，用最宽那段的中点量出带高，
  /// 再按胶囊自己的中线重扫占位——压不压到宿主控件，只在它实际落位那条线上才有意义。
  function scanBar() {
    const w = host.offsetWidth || 180, h = host.offsetHeight || 22;
    const width = window.innerWidth, need = w + 12;
    const probe = runsOf(sampleRow(Math.round(BAR_FALLBACK / 2)), need, width);
    const widest = probe.length
      ? probe.reduce((a, b) => (b.to - b.from > a.to - a.from ? b : a))
      : null;
    const band = widest ? barBand(Math.round((widest.from + widest.to) / 2)) : BAR_FALLBACK;
    const top = Math.max(0, Math.round((band - h) / 2));
    const y = Math.max(2, Math.min(band - 2, top + Math.round(h / 2)));
    const busy = sampleRow(y);
    return { width, band, top, busy, runs: runsOf(busy, need, width) };
  }

  /// 吸附位：竖向在深色带里居中，横向取能放下胶囊的最右一段空位。
  function dockSlot(scan) {
    const h = host.offsetHeight || 22;
    const s = scan || scanBar();
    if (s.band <= h || !s.runs.length) return null;
    const run = s.runs[s.runs.length - 1];
    return { top: s.top, right: Math.max(4, Math.round(s.width - run.to - 2)) };
  }

  /// 该落位是否压住了宿主自己的控件。压住就算想吸附——那片位置本来就不能停。
  function coversControls(pos, scan) {
    const w = host.offsetWidth || 180;
    const width = scan ? scan.width : window.innerWidth;
    const rightEdge = width - pos.right;
    for (let x = rightEdge - w + 6; x < rightEdge - 6; x += 12) {
      if (scan) { if (scan.busy[bandIndex(x)]) return true; }
      else if (occupied(x, Math.round(BAR_FALLBACK / 2))) return true;
    }
    return false;
  }

  const docked = () => {
    const flag = store.get(LS.dock);
    if (flag != null) return flag === '1';
    // 未表态过的旧安装：位置还停在初版默认值（右上角、压着宿主控件）时视为愿意吸附。
    const p = saved();
    return p.top === HOME.top && p.right === HOME.right;
  };

  // 吸附位移带一段过渡；自由拖动时必须没有过渡，否则跟不上手。
  function glide(on) {
    host.style.transition = on ? 'top .18s cubic-bezier(.32,.72,0,1), right .18s cubic-bezier(.32,.72,0,1)' : '';
  }

  // 夹到视口内：窗口缩小后控件曾能停在可视区外，只能清 localStorage 才找得回。
  function clamp(p) {
    const w = host.offsetWidth || 180, h = host.offsetHeight || 22;
    return {
      top: Math.min(Math.max(0, p.top), Math.max(0, window.innerHeight - h)),
      right: Math.min(Math.max(0, p.right), Math.max(0, window.innerWidth - w)),
    };
  }

  function apply(p) {
    setStyle(host, 'top', p.top + 'px');
    setStyle(host, 'right', p.right + 'px');
  }

  /// 当前实际落位（吸附态下 localStorage 里的坐标可能是解除吸附前的旧值，
  /// 拖动必须从眼睛看到的位置起算）。
  function current() {
    const r = host.getBoundingClientRect();
    if (!r.width) return saved();
    return { top: Math.round(r.top), right: Math.round(window.innerWidth - r.right) };
  }

  /// 当前实际落位。吸附态下 localStorage 里的坐标可能是解除吸附前的旧值，
  /// 拖动必须从眼睛看到的位置起算。
  function current() {
    const r = host.getBoundingClientRect();
    if (!r.width) return saved();
    return { top: Math.round(r.top), right: Math.round(window.innerWidth - r.right) };
  }

  function place(animate) {
    const slot = docked() ? dockSlot() : null;
    if (animate) { glide(true); setTimeout(() => glide(false), 260); }
    apply(clamp(slot || saved()));
  }

  let drag = null;
  pill.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    // 命中测试只在按下时做一次：拖动中宿主布局不变，逐帧重扫会把主线程占住。
    const scan = scanBar();
    const from = current();
    drag = { x: e.clientX, y: e.clientY, moved: false, from, at: from,
             scan, slot: dockSlot(scan) };
    e.preventDefault();
  });

  window.addEventListener('mousemove', (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) > 3) {
      drag.moved = true;
      root.classList.add('dragging');
    }
    if (!drag.moved) return;
    const free = clamp({ top: drag.from.top + dy, right: drag.from.right - dx });
    const slot = drag.slot;
    // 竖向贴着标题栏，且「横向靠近吸附位」或「这个落位会压住宿主控件」二者之一即命中。
    const near = !!slot && Math.abs(free.top - slot.top) <= SNAP_Y
      && (Math.abs(free.right - slot.right) <= SNAP_X || coversControls(free, drag.scan));
    drag.snap = !!near;
    drag.at = near ? slot : free;
    pill.classList.toggle('snap', !!near);
    apply(drag.at);
    if (state.open) position();
  });

  window.addEventListener('mouseup', () => {
    if (!drag) return;
    const moved = drag.moved, at = drag.at, snap = drag.snap;
    drag = null;
    root.classList.remove('dragging');
    pill.classList.remove('snap');
    if (!moved) { toggle(); return; }
    // 落盘只在松手时做一次：拖动中每帧写 localStorage 是同步磁盘写。
    // 吸附态只记一个标志，坐标随宿主布局重算；拖走即解除吸附。
    store.set(LS.dock, snap ? '1' : '0');
    store.set(LS.top, String(at.top));
    store.set(LS.right, String(at.right));
  });

  function toggle() {
    state.open = !state.open;
    if (!state.open) disarmQuit();
    paint();
    if (state.open) poll();
  }

  // 点别处收起。
  window.addEventListener('mousedown', (e) => {
    if (!state.open) return;
    if (e.composedPath().includes(host)) return;
    state.open = false;
    disarmQuit();
    paint();
  }, true);

  // Esc 收起，与「点别处」同义。
  const onKey = (e) => {
    if (e.key !== 'Escape' || !state.open) return;
    state.open = false;
    disarmQuit();
    paint();
  };
  window.addEventListener('keydown', onKey, true);
  cleanup.push(() => window.removeEventListener('keydown', onKey, true));

  const onResize = () => { place(); if (state.open) position(); };
  // 宿主布局在窗口尺寸不变时也会动（标签增减、右侧控件出现或收起），
  // 故吸附态每轮取数后重算一次落位。扫描是十几次命中测试，开销可忽略。
  const redock = () => { if (docked() && !drag) place(true); };
  window.addEventListener('resize', onResize);
  cleanup.push(() => window.removeEventListener('resize', onResize));

  /// 展开层落位：优先胶囊下方，下方装不下就翻到上方，两侧都夹进视口。
  function position() {
    const r = pill.getBoundingClientRect();
    const w = pop.offsetWidth || 300, h = pop.offsetHeight || 300;
    const gap = 7, pad = 8;
    let top = r.bottom + gap, origin = 'top right';
    if (top + h > window.innerHeight - pad) {
      const above = r.top - gap - h;
      if (above >= pad) { top = above; origin = 'bottom right'; }
      else { top = Math.max(pad, window.innerHeight - pad - h); }
    }
    const right = Math.min(Math.max(window.innerWidth - r.right, pad),
                           Math.max(pad, window.innerWidth - w - pad));
    setStyle(pop, 'top', top + 'px');
    setStyle(pop, 'right', right + 'px');
    setStyle(pop, 'transformOrigin', origin);
  }

  /* ---------------- 退出（两步） ---------------- */

  let quitTimer = 0;

  function disarmQuit() {
    clearTimeout(quitTimer);
    if (!state.quitAsked) return;
    state.quitAsked = false;
    els.quit.classList.remove('armed');
    els.quit.textContent = '退出';
  }

  els.quit.addEventListener('click', () => {
    if (state.quitSent) return;
    if (!state.quitAsked) {
      // 退出会让菜单栏进程停掉、控件随之停更，先要一次确认。
      state.quitAsked = true;
      els.quit.classList.add('armed');
      els.quit.textContent = '确认退出';
      clearTimeout(quitTimer);
      quitTimer = setTimeout(disarmQuit, 3000);
      return;
    }
    disarmQuit();
    state.quitSent = true;
    els.quit.textContent = '已请求退出';
    fetch(feed + '/quit', {
      method: 'POST',
      headers: { 'X-MiraQuota-Token': window.__MIRAQUOTA_TOKEN__ || '' },
    }).catch(() => {});
  });

  /* ---------------- 绘制 ---------------- */

  function paint() {
    try {
      draw();
    } catch (e) {
      // 控件出错不该静默消失：留个全局痕迹，注入器与排查都能看到。
      window.__miraquotaError = String((e && e.stack) || e);
    }
  }

  function draw() {
    const d = state.data;
    const now = Date.now() / 1000;
    const stale = !!state.err || (d && now - d.capturedAt > STALE_S);
    root.classList.toggle('stale', !!stale);

    // 圆点只编码通道状态；用量档位改由数字与百分比胶囊的颜色表达，
    // 两个信号不再互相覆盖。
    const stateKey = state.err ? '' : (d && d.state) || '';
    // 有请求在途时胶囊上的点跟着跳：收起状态下这是唯一能看出「正在生成」的地方，
    // 详情层里的「生成中」标记要展开才看得到。
    const busy = !!(d && d.speed && (d.speed.inflight || []).length);
    setTone(els.dot, 'dot', (stateKey + (busy ? ' busy' : '')).trim());
    setTone(els.cdot, 'dot', stateKey);

    drawPill(d);

    setTone(els.chip, 'chip', state.err ? 'warn' : d && d.measured ? 'ok' : 'warn');
    setTick(els.clabel, d ? (d.stateLabel + (stale ? ' · ' + ago(d.capturedAt) : ''))
      : (state.err ? '接口不可达' : '连接中'));

    pop.classList.toggle('on', state.open);
    if (!state.open) return;

    drawBanners(d);
    drawCards(d, now);
    drawSpeed(d);
    drawFooter(d);
    position();
  }

  function drawPill(d) {
    if (!d || !d.windows.length) {
      setText(els.lb1, '额度');
      setText(els.v1, '—');
      setText(els.u1, '');
      setHidden(els.sep, true);
      setHidden(els.seg2, true);
      return;
    }
    const primary = d.windows.find((w) => w.label === '5h') || d.windows[0];
    // 第二段取占比最高的长窗口：窗口不止 5h/7d 两个（现有 7d_fable），
    // 固定显示 7d 会漏掉真正吃紧的那个。
    const rest = d.windows.filter((w) => w !== primary);
    const second = rest.length
      ? rest.reduce((a, b) => (b.usedPercent > a.usedPercent ? b : a))
      : null;

    setText(els.lb1, winShort(primary.label));
    setText(els.v1, (primary.inferred ? '≈' : '') + pct(primary.usedPercent));
    setTone(els.v1, 'v', toneOf(primary.usedPercent));
    setText(els.u1, primary.scaledSpentUSD == null && primary.fullUSD == null && primary.points
      ? kilo(primary.points.used) + ' 点'
      : usd(primary.scaledSpentUSD != null ? primary.scaledSpentUSD : primary.spentUSD));

    setHidden(els.sep, !second);
    setHidden(els.seg2, !second);
    if (second) {
      setText(els.lb2, winShort(second.label));
      setText(els.v2, (second.inferred ? '≈' : '') + pct(second.usedPercent));
      setTone(els.v2, 'v', toneOf(second.usedPercent));
    }

    pill.title = d.windows
      .map((w) => `${winTitle(w.label)} ${pct(w.usedPercent)}`)
      .join('　') + (d.stateLabel ? `\n${d.stateLabel}` : '');
  }

  // 横幅数量随状态变化，按需增删，文本走 textContent 不拼 HTML。
  function drawBanners(d) {
    const lines = [];
    if (state.err) lines.push(`读不到本机接口（${feed}）：${state.err}`);
    if (state.quitSent) lines.push('已请求退出，菜单栏进程停止后本控件不再更新。');
    if (d && d.accountNotice) lines.push(d.accountNotice);
    if (d && d.detail) lines.push(d.detail);
    const box = els.banners;
    while (box.children.length > lines.length) box.lastChild.remove();
    while (box.children.length < lines.length) {
      const el = document.createElement('div');
      el.className = 'banner';
      box.appendChild(el);
    }
    lines.forEach((text, i) => setText(box.children[i], text));
  }

  const cards = new Map();

  function cardFor(label) {
    let c = cards.get(label);
    if (c) return c;
    const el = document.createElement('div');
    el.className = 'card';
    el.innerHTML = `<div class="crow"><span class="wl"></span>`
      + `<span class="amt"><b></b> <i></i></span><span class="pc"></span></div>`
      + `<div class="bar"><div class="fill"></div><div class="pace" hidden></div></div>`
      + `<div class="foot"><span class="left"></span><span class="eta"></span><span class="r"></span></div>`
      + `<div class="sub"></div>`;
    c = {
      el,
      wl: el.querySelector('.wl'), amt: el.querySelector('.amt b'), full: el.querySelector('.amt i'),
      pc: el.querySelector('.pc'), fill: el.querySelector('.fill'), pace: el.querySelector('.pace'),
      left: el.querySelector('.left'), eta: el.querySelector('.eta'), right: el.querySelector('.r'),
      sub: el.querySelector('.sub'),
    };
    cards.set(label, c);
    return c;
  }

  function drawCards(d, now) {
    const windows = d ? d.windows : [];
    const seen = new Set();
    windows.forEach((w, i) => {
      seen.add(w.label);
      const c = cardFor(w.label);
      const tone = toneOf(w.usedPercent);
      setTone(c.el, 'card', i === 0 ? 'primary' : '');
      // 展开动画的落位次序，见 CSS 的 mqCardIn / mqBarIn。
      // 自定义属性只能走 setProperty：`style['--i'] = x` 是静默无效的，
      // 三张卡的序号都取不到，错峰就退化成同时出现。
      setVar(c.el, '--i', String(i));
      setText(c.wl, winTitle(w.label));
      // 主行按点数口径折算，与百分比、进度条同分母；账本支出落到副行。
      // 满额不可用而点数在手时主行改用点数：此时账本已判定不自洽，不该被抬到主行。
      const headPoints = w.scaledSpentUSD == null && w.fullUSD == null && w.points;
      setText(c.amt, headPoints ? kilo(w.points.used) + ' 点'
        : usd(w.scaledSpentUSD != null ? w.scaledSpentUSD : w.spentUSD));
      setText(c.full, '/ ' + (w.fullUSD == null ? '标定中'
        : (w.confidence === 'high' ? '' : '~') + usd(w.fullUSD)));
      setText(c.pc, (w.inferred ? '≈' : '') + pct(w.usedPercent));
      setTone(c.pc, 'pc', tone);
      setStyle(c.fill, 'width', Math.min(100, Math.max(0, w.usedPercent)) + '%');
      setTone(c.fill, 'fill', tone);
      const showPace = w.pacePercent > 1 && w.pacePercent < 99;
      setHidden(c.pace, !showPace);
      if (showPace) setStyle(c.pace, 'left', w.pacePercent + '%');

      if (w.remainingUSD != null) {
        setText(c.left, `余 ${w.confidence === 'high' ? '' : '~'}${usd(w.remainingUSD)}`);
        if (w.etaSeconds == null) {
          setText(c.eta, '');
        } else if (w.resetAt && now + w.etaSeconds >= w.resetAt) {
          setText(c.eta, '· 到重置不满');
          setTone(c.eta, 'eta', '');
        } else {
          // 有底色的徽标自成一段，前面再挂个顿点会显得它是上一段的续写。
          setText(c.eta, `≈${fmtDur(w.etaSeconds)}后打满`);
          setTone(c.eta, 'eta', 'soon');
        }
      } else {
        setText(c.left, w.paceDelta == null ? '滚动窗口'
          : `均速 ${Math.round(w.pacePercent)}% · ${w.paceDelta >= 0 ? '超出' : '低于'} ${Math.abs(w.paceDelta).toFixed(1)}%`);
        setText(c.eta, '');
      }
      setTick(c.right, w.resetAt ? countdown(w.resetAt - now) : '无固定重置');

      const bits = [];
      if (w.scaledSpentUSD != null || headPoints) bits.push('账本 ' + usd(w.spentUSD));
      if (w.points) bits.push(`${kilo(w.points.used)}/${kilo(w.points.budget)} 点`);
      setText(c.sub, bits.join(' · '));
      setHidden(c.sub, !bits.length);

      const at = els.cards.children[i];
      if (at !== c.el) els.cards.insertBefore(c.el, at || null);
    });
    for (const [label, c] of cards) {
      if (!seen.has(label)) { c.el.remove(); cards.delete(label); }
    }
  }

  const speedRows = new Map();
  let speedCard = null;

  function speedSkeleton() {
    if (speedCard) return speedCard;
    const el = document.createElement('div');
    el.className = 'card';
    el.innerHTML = `<div class="crow" style="grid-template-columns:auto 1fr"><span class="wl">速度</span>`
      + `<span class="tag" style="justify-self:end;font-size:9.5px"></span></div>`
      + `<div class="rows"></div>`
      + `<div class="none" style="margin-top:5px;color:var(--ink2);font-size:10px"></div>`;
    // 排在窗口卡之后落位；窗口数不定，取一个够大的序号即可。
    el.style.setProperty('--i', '3');

    speedCard = {
      el, tag: el.querySelector('.tag'), rows: el.querySelector('.rows'),
      none: el.querySelector('.none'), pulse: null,
    };
    return speedCard;
  }

  function speedRowFor(model) {
    let r = speedRows.get(model);
    if (r) return r;
    const el = document.createElement('div');
    el.className = 'sp';
    el.innerHTML = `<span class="m"></span><span class="v"></span><span class="dr"></span><span class="n"></span>`;
    r = { el, m: el.querySelector('.m'), v: el.querySelector('.v'),
          dr: el.querySelector('.dr'), n: el.querySelector('.n') };
    speedRows.set(model, r);
    return r;
  }

  function drawSpeed(d) {
    const sp = d && d.speed;
    if (!sp) {
      if (speedCard) speedCard.el.remove();
      return;
    }
    const c = speedSkeleton();
    if (c.el.parentNode !== els.speedbox) els.speedbox.appendChild(c.el);

    const flying = (sp.inflight || []).length;
    if (flying) {
      const oldest = Math.min.apply(null, sp.inflight);
      const secs = Math.round(Date.now() / 1000 - oldest);
      if (!c.pulse) {
        c.tag.innerHTML = `<span class="live"><span class="pulse"></span><span class="txt"></span></span>`;
        c.pulse = c.tag.querySelector('.txt');
      }
      setTick(c.pulse, `生成中 ${flying} 条 · 已 ${secs} 秒`);
    } else {
      if (c.pulse) { c.tag.textContent = ''; c.tag.__v = undefined; c.pulse = null; }
      c.tag.style.color = 'var(--ink3)';
      setText(c.tag, `最近 ${sp.recentCount} 次`);
    }

    const rows = sp.rows || [];
    setHidden(c.none, rows.length > 0 || flying > 0);
    setText(c.none, rows.length || flying ? '' : `近期无请求（${sp.sampleTotal} 次）`);

    const seen = new Set();
    rows.forEach((row, i) => {
      seen.add(row.model);
      const r = speedRowFor(row.model);
      setText(r.m, shortModel(row.model));
      r.m.title = row.model;
      // measured 为真时首 token 是逐请求实测值，不带 ≈；缺字段按回归行处理。
      setText(r.v, row.rate == null ? `端到端 ${row.endToEnd.toFixed(0)} tok/s`
        : (row.ttft != null ? `首 ${row.measured ? '' : '≈'}${row.ttft.toFixed(1)}s · ` : '') + `${row.rate.toFixed(0)} tok/s`);
      // 阈值由 Swift 侧统一把关（SpeedRow.notableDrift），这里只显示给了值的那一档。
      const drift = row.driftNotable;
      setText(r.dr, drift == null ? '' : `${drift > 0 ? '快' : '慢'}${Math.abs(drift).toFixed(0)}%`);
      setTone(r.dr, 'dr', drift == null ? '' : drift > 0 ? 'fast' : 'slow');
      setTick(r.n, ago(row.latestAt));
      const at = c.rows.children[i];
      if (at !== r.el) c.rows.insertBefore(r.el, at || null);
    });
    for (const [model, r] of speedRows) {
      if (!seen.has(model)) { r.el.remove(); speedRows.delete(model); }
    }
  }

  function drawFooter(d) {
    if (!d) {
      setHidden(els.rowFull, true);
      setHidden(els.rowLedger, true);
      setHidden(els.rowLine, true);
      setText(els.stamp, '');
      return;
    }
    setHidden(els.rowFull, !d.unitPriceUSD && !d.unitPriceNotice);
    if (d.unitPriceUSD) {
      setText(els.metaFull, `回归标定优先 · 兜底 额度点 × $${d.unitPriceUSD.toFixed(6)}`);
    } else if (d.unitPriceNotice) {
      setText(els.metaFull, d.unitPriceNotice);
    }
    // 只有 windows / capturedAt / state / stateLabel 是必填字段（见 docs/ARCHITECTURE.md），
    // 其余按有值的部分拼，缺项不显示——否则精简的 provider 会在这一行显示 undefined。
    const ledger = [];
    if (d.buckets != null) ledger.push(`${d.buckets} 分钟桶`);
    if (d.pricing) ledger.push(d.pricing);
    setHidden(els.rowLedger, !ledger.length);
    setText(els.metaLedger, ledger.join(' · '));

    const line = [];
    if (d.mode || d.host) line.push([d.mode, d.host].filter(Boolean).join(' '));
    if (d.relayStatus) line.push(d.relayStatus);
    setHidden(els.rowLine, !line.length);
    setText(els.metaLine, line.join(' · '));
    // 整行的完整取值挂在 title 上：值列过长时截尾，鼠标停住仍读得到。
    els.metaLine.title = line.join(' · ');
    setTick(els.stamp, clock(d.capturedAt));
  }

  /* ---------------- 主题与挂载 ---------------- */

  // 宿主背景的相对亮度。返回 null 表示背景透明或读不出，交给下一级判据。
  function hostLuma() {
    for (const el of [document.body, document.documentElement]) {
      if (!el) continue;
      const bg = getComputedStyle(el).backgroundColor || '';
      const m = bg.match(/rgba?\(([^)]+)\)/);
      if (!m) continue;
      const parts = m[1].split(',').map((x) => parseFloat(x));
      if (parts.length >= 4 && parts[3] < 0.5) continue;
      const [r, g, b] = parts;
      if (![r, g, b].every((x) => Number.isFinite(x))) continue;
      return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    }
    return null;
  }

  function applyTheme() {
    const attr = (document.documentElement.getAttribute('data-theme') || '').toLowerCase();
    let light;
    if (attr.includes('light')) light = true;
    else if (attr.includes('dark')) light = false;
    else {
      // Mirasim 现在给的是 data-theme=dark；宿主若哪天改了机制，
      // 背景亮度仍能判出来。系统偏好只作最后一级：本机实测系统为浅色而
      // Mirasim 界面为深色，只看系统偏好会把浅色控件贴到深色界面上。
      const luma = hostLuma();
      light = luma == null ? !window.matchMedia('(prefers-color-scheme: dark)').matches
        : luma > 0.45;
    }
    root.classList.toggle('light', light);
  }

  function applyMotion() {
    try { root.classList.toggle('rm', window.matchMedia('(prefers-reduced-motion: reduce)').matches); }
    catch (e) { /* 老接口 */ }
  }

  function mount() {
    if (host.isConnected || !document.body) return;
    // 清掉早前注入留下的同名宿主，避免页面里叠出多份控件。
    for (const old of document.querySelectorAll('#' + host.id)) {
      if (old !== host) old.remove();
    }
    host.style.cssText = 'position:fixed;z-index:2147483645;'
      + '-webkit-app-region:no-drag;app-region:no-drag;';
    document.body.appendChild(host);
    place();
  }

  function boot() {
    const docEl = document.documentElement;
    // 注入发生在文档开始时，此刻 documentElement / body 可能都还不存在。
    if (!docEl) {
      document.addEventListener('readystatechange', boot, { once: true });
      return;
    }
    applyTheme();
    applyMotion();
    const themeMo = new MutationObserver(applyTheme);
    themeMo.observe(docEl, { attributes: true, attributeFilter: ['data-theme', 'class', 'style'] });
    // 界面重绘可能把宿主摘掉，盯着 DOM 重新挂回去。
    const mountMo = new MutationObserver(mount);
    mountMo.observe(docEl, { childList: true, subtree: true });
    cleanup.push(() => themeMo.disconnect(), () => mountMo.disconnect());
    try {
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);
      window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', applyMotion);
    } catch (e) { /* 老接口，忽略 */ }

    mount();
    paint();
    poll();
    // 轮询节奏随在途情况自适应：有生成中的请求就每 2 秒拉一次，空闲时 5 秒。
    let timer = 0;
    const schedule = () => {
      clearTimeout(timer);
      const inflight = ((state.data || {}).speed || {}).inflight || [];
      timer = setTimeout(async () => { await poll(); redock(); schedule(); },
                         inflight.length ? POLL_MS_LIVE : POLL_MS);
    };
    schedule();
    // 展开时每秒重绘，让倒计时与"已 N 秒"走动。骨架复用后这一次重绘只改文本。
    const tick = setInterval(() => { if (state.open) paint(); }, 1000);
    cleanup.push(() => clearTimeout(timer), () => clearInterval(tick));
  }

  try {
    boot();
  } catch (e) {
    window.__miraquotaError = String((e && e.stack) || e);
  }
})();
