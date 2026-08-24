#!/bin/bash
# 构建 release 二进制并组装成 MiraQuota.app（菜单栏应用，无 Dock 图标）。
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/MiraQuota.app"

# SwiftUI 的宏插件只在完整 Xcode 里，CommandLineTools 编不过（缺 Platforms 目录即判为不完整）。
# 依次试：DEVELOPER_DIR、xcode-select 选定的、/Applications 下的 Xcode*.app。
find_developer_dir() {
  local d
  for d in "${DEVELOPER_DIR:-}" "$(xcode-select -p 2>/dev/null || true)" \
           /Applications/Xcode.app/Contents/Developer \
           /Applications/Xcode*.app/Contents/Developer; do
    [ -n "$d" ] && [ -d "$d/Platforms/MacOSX.platform" ] && { echo "$d"; return 0; }
  done
  return 1
}

if ! DEV_DIR="$(find_developer_dir)"; then
  echo "未找到完整 Xcode。安装 Xcode 16 或更新（需 Swift 6 工具链），" >&2
  echo "或设置 DEVELOPER_DIR 指向 Xcode.app/Contents/Developer。" >&2
  echo "仅装 CommandLineTools 无法编译：SwiftUI 的宏插件不在其中。" >&2
  exit 1
fi
echo "工具链 $DEV_DIR"

DEVELOPER_DIR="$DEV_DIR" swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MiraQuota "$APP/Contents/MacOS/MiraQuota"
# 客户端内控件的脚本，由注入器读取后经 CDP 送进 Mirasim 的渲染进程。
cp widget/miraquota-widget.js "$APP/Contents/Resources/widget.js"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MiraQuota</string>
  <key>CFBundleIdentifier</key><string>local.miraquota</string>
  <key>CFBundleName</key><string>MiraQuota</string>
  <key>CFBundleDisplayName</key><string>额度</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ad-hoc 签名，避免 Gatekeeper 在本机拦下未签名的包。
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成 $APP"
echo "启动：open $APP        自检：$APP/Contents/MacOS/MiraQuota --once"
