#!/bin/bash
# 实验 19（B8）：真人把「访达」从 Dock 移除后，Dock 会不会往偏好域里写新键（"落键"）？
#
# 背景：P0 实测（spikes.md 实验 3）Finder 在 com.apple.dock 全量域里**没有任何表示**，
# "钉住"天然成立。但 Finder 的「在 Dock 中保留」是可以关掉的 —— 关掉那一刻 Dock
# 必须把"Finder 被明确移除"记在某处；如果它写了一个新键，MultiDock 的白名单/备份
# 语义就要考虑它。这正是 B8。
#
# **本脚本只读**：快照当前域 → 提示用户移除 Finder → 轮询 diff（默认 60 s）→ 报告差异
# → 提醒把 Finder 拖回去。不改任何偏好、不重启 Dock。
#
# 用法：./scripts/check-finder-removal.sh [观察秒数，默认 60]
# 判读：差异若只落在 mod-count / recent-apps / trash-full / GUID → 无新键，B8 关闭；
#       出现任何其他键 → 把键名记进 docs/facts.md，并评估是否纳入白名单。
set -uo pipefail
WAIT="${1:-60}"
OUT=/tmp/multidock-b8
mkdir -p "$OUT"
BEFORE="$OUT/before.plist"
NOW="$OUT/now.plist"

defaults export com.apple.dock "$BEFORE"
echo "已快照当前域 → $BEFORE"
echo
echo ">>> 请现在操作（$WAIT 秒内）：右键 Dock 上的「访达」图标 → 选项 → 取消勾选「在 Dock 中保留」"
echo ">>> （做完就等脚本报告；结束后记得把 Finder 拖回 Dock，否则重启后 Dock 上没有访达）"
echo

deadline=$((SECONDS + WAIT))
changed=0
while (( SECONDS < deadline )); do
  defaults export com.apple.dock "$NOW" 2>/dev/null
  if [[ -s "$NOW" ]] && ! cmp -s "$BEFORE" "$NOW"; then
    changed=1
    echo "检测到域变化（$(date +%H:%M:%S)）："
    break
  fi
  sleep 1
done

if (( ! changed )); then
  echo "=== $WAIT 秒内域无变化 —— 若你已完成移除操作，说明移除 Finder 不落键（B8 可关）；若没来得及操作，重跑一次加长窗口。"
  exit 0
fi

diff <(plutil -convert xml1 -o - "$BEFORE") <(plutil -convert xml1 -o - "$NOW") | rg "^[<>]" | head -40
echo
echo ">>> 判读：差异只落在 mod-count / recent-apps / trash-full / GUID → 无新键，B8 关闭；"
echo ">>>       出现其他键名 → 记进 docs/facts.md 并评估是否纳入白名单。"
echo ">>> 现在请把「访达」拖回 Dock（从应用程序文件夹拖到最左端）。"
