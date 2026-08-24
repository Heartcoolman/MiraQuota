#!/bin/bash
# 生成一个启动器：以后从它打开 Mirasim，就总是带着调试端口，控件自然出现。
# Mirasim 只从命令行接受 --remote-debugging-port，没有环境变量或配置项可设（已核对 app.asar）。
set -euo pipefail

PORT="${1:-9333}"
APP="$HOME/Applications/Mirasim（带控件）.app"
BIN="$APP/Contents/MacOS/launcher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$BIN" <<LAUNCH
#!/bin/bash
# 已带调试端口在跑：只把窗口带到前面，不重启（避免断掉正在转发的会话）。
if curl -s -m 1 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
  open -a Mirasim
  exit 0
fi
# 在跑但没带端口：退出旧实例再带端口重开。
# 用 AppleScript 判运行状态——macOS 的 pgrep 对 Electron 主进程命令行匹配不可靠。
if [ "\$(osascript -e 'application "Mirasim" is running' 2>/dev/null)" = "true" ]; then
  osascript -e 'tell application "Mirasim" to quit' >/dev/null 2>&1 || true
  for _ in \$(seq 1 40); do
    [ "\$(osascript -e 'application "Mirasim" is running' 2>/dev/null)" = "true" ] || break
    sleep 0.25
  done
  PIDS=\$(ps -Ao pid,args | grep -F 'Mirasim.app/Contents/MacOS/Mirasim' | grep -v grep | awk '{print \$1}')
  [ -n "\$PIDS" ] && kill \$PIDS 2>/dev/null || true
  sleep 1
fi
exec open -na Mirasim --args --remote-debugging-port=$PORT
LAUNCH
chmod +x "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIdentifier</key><string>local.miraquota.mirasim-launcher</string>
  <key>CFBundleName</key><string>Mirasim（带控件）</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 用 Mirasim 自己的图标，让 Dock 里看起来就是 Mirasim。
cp /Applications/Mirasim.app/Contents/Resources/icon.icns "$APP/Contents/Resources/icon.icns" 2>/dev/null || true

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "已生成 $APP"
echo "以后从它打开 Mirasim（可拖到 Dock），就总带调试端口 ${PORT}"
