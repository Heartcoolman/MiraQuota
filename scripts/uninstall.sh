#!/bin/bash
# 卸载 LaunchAgent 与应用。默认保留 ~/.miraquota 里的标定样本与锚点，
# 传 --purge 一并删除（删除后满额需要重新标定）。
set -euo pipefail

LABEL="local.miraquota"
DEST="$HOME/Applications/MiraQuota.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

LAUNCHER="$HOME/Applications/Mirasim（带控件）.app"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
pkill -x MiraQuota 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$DEST"
echo "已移除自启与应用"

# 从 Dock 撤下启动器再删除；否则 Dock 会留一个失效条目。
# 读写都走 defaults（即 cfprefsd）：直接改 plist 文件会被 cfprefsd 的内存缓存
# 回刷覆盖，删除静默失效或吞掉 Dock 未落盘的其他改动。
if [ -e "$LAUNCHER" ]; then
  python3 - "$LAUNCHER" <<'PY' 2>/dev/null || true
import subprocess,plistlib,os,sys,urllib.parse
target=os.path.realpath(sys.argv[1])
d=plistlib.loads(subprocess.run(['defaults','export','com.apple.dock','-'],capture_output=True,check=True).stdout)
apps=d.get('persistent-apps',[])
def path(a):
    u=a.get('tile-data',{}).get('file-data',{}).get('_CFURLString','')
    return os.path.realpath(urllib.parse.unquote(u.replace('file://','')).rstrip('/'))
kept=[a for a in apps if path(a)!=target]
if len(kept)!=len(apps):
    d['persistent-apps']=kept
    subprocess.run(['defaults','import','com.apple.dock','-'],input=plistlib.dumps(d),check=True)
    subprocess.run(['killall','Dock'])
    print('已从 Dock 撤下启动器')
PY
  rm -rf "$LAUNCHER"
  echo "已删除 Mirasim 启动器"
fi

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.miraquota"
  echo "已删除 ~/.miraquota（标定样本与窗口锚点）"
else
  echo "保留 ~/.miraquota；如需一并删除：./scripts/uninstall.sh --purge"
fi
