#!/bin/bash
# 安装到 ~/Applications 并注册 LaunchAgent，登录时随 Mirasim 一同起来。
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="local.miraquota"
DEST="$HOME/Applications/MiraQuota.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$DEST/Contents/MacOS/MiraQuota"
LOG="$HOME/.miraquota/agent.log"

./scripts/bundle.sh

# 客户端里已有控件时是否保留菜单栏图标（两处同时显示）。装过一次就沿用上次的选择，
# 首次安装可用 MIRAQUOTA_STATUS_ALWAYS=1 ./scripts/install.sh 打开。
PRIOR=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:MIRAQUOTA_STATUS_ALWAYS" "$PLIST" 2>/dev/null || true)
ENV_BLOCK=""
if [ "${MIRAQUOTA_STATUS_ALWAYS:-$PRIOR}" = "1" ]; then
  ENV_BLOCK='  <key>EnvironmentVariables</key>
  <dict><key>MIRAQUOTA_STATUS_ALWAYS</key><string>1</string></dict>'
fi

# 装到 ~/Applications 而非 build/，避免仓库移动或清理后自启指向空路径。
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/.miraquota"
rm -rf "$DEST"
cp -R build/MiraQuota.app "$DEST"

# 重建包会让 LaunchServices 的注册变陈旧，紧接着启动的进程拿不到菜单栏位置
# （进程在跑、状态栏项也建出来了，但不显示）。必须重新注册。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST"

# 旧实例先停掉，否则会残留两个菜单栏图标。
# bootout 是异步的：作业未拆除完就 bootstrap 会以 EIO 失败，必须等它真的消失。
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x MiraQuota 2>/dev/null || true
for _ in $(seq 1 60); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <!-- 登录时只常驻：不开窗口、不占 Dock。从 Dock 点图标才开窗。 -->
  <array><string>$BIN</string><string>--background</string></array>
  <key>RunAtLoad</key><true/>
$ENV_BLOCK
  <!-- 崩溃才拉起；从面板点「退出」是正常退出，保持退出状态直到下次登录。 -->
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <!-- 必须绑到 Aqua 会话：这是有菜单栏 UI 的 agent，
       不能声明 ProcessType=Background，那样拿不到状态栏位置。 -->
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

# 只用 bootstrap。不回退到 legacy 的 launchctl load：那样加载的 agent
# 虽然进程能跑，却拿不到菜单栏位置，表现为「装好了但图标不出现」。
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  echo "launchctl bootstrap 失败；稍后重试或先执行 ./scripts/uninstall.sh" >&2
  exit 1
fi

# 确认作业真的起来了，别只看脚本没报错。
for _ in $(seq 1 40); do
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running" && break
  sleep 0.25
done
if ! launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
  echo "作业已注册但未运行，查看 ${LOG}" >&2
  exit 1
fi

# 包刚被重建，紧接着启动的那次拿不到菜单栏位置。等注册落定后再踢一次作业，
# 第二次启动面对的是稳定的包，图标才会出现。
sleep 1
launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  pgrep -x MiraQuota >/dev/null 2>&1 && break
  sleep 0.25
done

# 顺带（重）生成带调试端口的 Mirasim 启动器；已钉在 Dock 上的条目指向它，重装后仍有效。
LAUNCHER="$HOME/Applications/Mirasim（带控件）.app"
if [ -e "$LAUNCHER" ] || [ "${MIRAQUOTA_MAKE_LAUNCHER:-1}" = "1" ]; then
  ./scripts/make-launcher.sh >/dev/null 2>&1 && echo "启动器 ${LAUNCHER}（点它带调试端口开 Mirasim，控件才出现）"
fi

echo "已安装 ${DEST}"
echo "打开   open -a MiraQuota（首次打开后可在 Dock 图标上右键 → 选项 → 在 Dock 中保留）"
echo "运行中 pid $(pgrep -x MiraQuota)"
echo "自启   ${PLIST}（登录时拉起，崩溃自动重启）"
echo "日志   ${LOG}"
echo "卸载   ./scripts/uninstall.sh"
echo "自检   ${BIN} --doctor"
