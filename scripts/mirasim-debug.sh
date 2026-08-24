#!/bin/bash
# 让 Mirasim 带 CDP 调试端口重启，MiraQuota 才能把控件注入它的界面。
#
# 注意：这会退出并重开 Mirasim。经它转发的 Claude Code / Codex 会话会断开网关，
# 需要重开会话；Mirasim 自身的对话记录不受影响。
set -euo pipefail

PORT="${1:-9333}"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "端口 $PORT 已在监听，Mirasim 可能已带调试端口运行；无需重启。"
  exit 0
fi

echo "将退出 Mirasim 并以 --remote-debugging-port=$PORT 重新启动。"
echo "经 Mirasim 转发的会话会断开，请确认无正在运行的长任务。"
osascript -e 'tell application "Mirasim" to quit' >/dev/null 2>&1 || true

for _ in $(seq 1 40); do
  [ "$(osascript -e 'application "Mirasim" is running' 2>/dev/null)" = "true" ] || break
  sleep 0.25
done
# 正常路径下 quit 已成功、grep 无匹配会让管道退出 1；set -e 之下不加 || true
# 脚本会在这里终止，Mirasim 被退出后再也不会重启。
PIDS=$(ps -Ao pid,args | grep -F 'Mirasim.app/Contents/MacOS/Mirasim' | grep -v grep | awk '{print $1}') || true
[ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
sleep 1

open -na Mirasim --args --remote-debugging-port="$PORT"

for _ in $(seq 1 60); do
  curl -s -m 1 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1 && break
  sleep 0.5
done

if curl -s -m 2 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
  echo "已启动，CDP 端点在 127.0.0.1:$PORT"
  echo "MiraQuota 每 10 秒巡检一次，控件随即出现在 Mirasim 界面右上角（可拖动）。"
else
  echo "Mirasim 已启动，但 $PORT 上没有 CDP 端点；确认该版本接受该参数。" >&2
  exit 1
fi
