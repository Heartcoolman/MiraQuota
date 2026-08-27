#!/bin/bash
# 给控件出图：起一个本地静态服务托住取景台，用无头 Chrome 截屏。
# 走 http 而不是 file://，是因为 file:// 页面的源是 opaque，
# localStorage 直接抛异常，控件会退到内存态，位置与吸附都测不出来。
#
# 用法：scripts/widget-shot.sh [dark|light] [输出路径] [虚拟时间预算 ms]
# 预算取小于展开时刻 +动画时长 的值即可截到动画中途，用来核对入场节奏。
set -euo pipefail

cd "$(dirname "$0")/.."
THEME="${1:-dark}"
OUT="${2:-/tmp/widget-$THEME.png}"
BUDGET="${3:-4000}"
# 端口取随机高位：固定端口会撞上上一次没退干净的服务，Chrome 抓到的是旧目录。
PORT=$(( 8800 + RANDOM % 400 ))
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

[ -x "$CHROME" ] || { echo "未找到 Google Chrome" >&2; exit 1; }

# 取景台与控件源都放在同一目录下供服务，脚本本体不动仓库里的源文件。
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null || true' EXIT
cp scripts/widget-preview.html "$STAGE/index.html"
cp widget/miraquota-widget.js "$STAGE/widget-preview-src.js"

(cd "$STAGE" && python3 -m http.server "$PORT" >/dev/null 2>&1) &
SRV=$!
for _ in $(seq 1 40); do
  curl -s -m 1 "http://127.0.0.1:$PORT/index.html" >/dev/null 2>&1 && break
  sleep 0.1
done

"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --virtual-time-budget="$BUDGET" --force-device-scale-factor=2 \
  --window-size=760,620 --screenshot="$OUT" \
  "http://127.0.0.1:$PORT/index.html?theme=$THEME" >/dev/null 2>&1

echo "$OUT"
