#!/bin/bash
# P0 实验：Dock 偏好改动后，三种"重载触发方式"哪种真的让 Dock 生效？
#
# 背景（见 docs/PLAN.md §3.5）：写 com.apple.dock 之后 Dock 未必重新读取。本脚本按
# "触发强度从小到大"逐级升级，每一级都记录客观信号 + 截图，找出最小的有效触发方式。
#
#   T0  只写偏好，不触发           —— Dock 会不会自己发现？
#   A   写偏好 + post 通知          —— com.apple.dock.prefchanged / AppleNoRedisplay...
#   B   kill -HUP                  —— 信号热重载
#   C   kill -TERM + kickstart     —— 重启进程（必然生效）
#
# 安全性：实验前把 com.apple.dock 全量域导出备份，结束时还原并强制重载；
#        中断（Ctrl-C / 报错）也会走 trap 还原。
#
# 用法：./scripts/spike-reload.sh [--dry-run] [--keep-going]
# 产物：$OUT/ 下 probe-*.txt（探测快照）、shot-*.png（Dock 区域截图）、summary.txt

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SPIKE_OUT:-/tmp/multidock-spike/run-$(date +%Y%m%d-%H%M%S)}"
PROBE="$PROJECT_DIR/scripts/spike-probe.swift"
PYTHON="${PYTHON:-/Users/apple/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3}"
DOCK_DOMAIN="com.apple.dock"
DOCK_AGENT="gui/$(id -u)/com.apple.Dock.agent"

TEST_APP="/System/Applications/Calculator.app"
TEST_LABEL="MultiDockSpikeTest"
TEST_TILESIZE=72          # 外观键实验值（默认 36）
WAIT_SETTLE=3             # 每级触发后等待秒数
WAIT_DOCK_BACK=5          # 等待 Dock 归位上限

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
BASELINE="$OUT/baseline.plist"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

log()  { echo "$*" | tee -a "$SUMMARY"; }
note() { echo "  $*" | tee -a "$SUMMARY"; }

dock_pid() { pgrep -x Dock | head -1; }

probe() {  # probe <tag>
  local tag="$1"
  swift "$PROBE" > "$OUT/probe-$tag.txt" 2>&1
  local pid; pid="$(dock_pid)"
  local active; active="$(sed -n 's/^activeSpaceUUID  : //p' "$OUT/probe-$tag.txt")"
  local tiles; tiles="$("$PYTHON" "$OUT/tile-state.py" "$TEST_LABEL" 2>/dev/null)"
  echo "$(date +%H:%M:%S) | tag=$tag | dockPID=${pid:-none} | activeSpace=$active | $tiles" >> "$SUMMARY"
}

shot() {  # shot <tag>  —— 裁切屏幕底部 Dock 区域
  local tag="$1"
  # 逻辑分辨率 1920x1200；Dock 在底部，抓最后 150pt 足够覆盖 36~72 的 tilesize
  screencapture -x -R 0,1050,1920,150 "$OUT/shot-$tag.png" 2>/dev/null
}

# ---------- 还原 ----------
restore_baseline() {
  echo
  echo ">>> 还原基准偏好…"
  if [[ -f "$BASELINE" ]]; then
    defaults import "$DOCK_DOMAIN" "$BASELINE"
    # 强制 Dock 重新读取（此时 C 已证明有效）
    local pid; pid="$(dock_pid)"
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
    sleep 1
    if [[ -z "$(dock_pid)" ]]; then
      launchctl kickstart -k "$DOCK_AGENT" >/dev/null 2>&1
      sleep 2
    fi
    echo ">>> 已还原。当前 Dock PID: $(dock_pid)"
    swift "$PROBE" > "$OUT/probe-restored.txt" 2>&1
    echo ">>> 还原后探测见 $OUT/probe-restored.txt"
  fi
}
trap 'restore_baseline' EXIT INT TERM

# ---------- 前置检查 ----------
if [[ -z "$(dock_pid)" ]]; then echo "错误：Dock 未运行" >&2; exit 1; fi
if [[ ! -d "$TEST_APP" ]]; then echo "错误：测试用 app 不存在 $TEST_APP" >&2; exit 1; fi

log "=== P0 Dock 重载策略实验 ==="
log "时间          : $(date '+%Y-%m-%d %H:%M:%S')"
log "产物目录      : $OUT"
log "测试 app      : $TEST_APP"
log "初始 Dock PID : $(dock_pid)"
log ""

# ---------- 备份 ----------
defaults export "$DOCK_DOMAIN" "$BASELINE"
log "已备份全量域 → $BASELINE ($(wc -c < "$BASELINE" | tr -d ' ') 字节)"
log ""

# ---------- 生成辅助脚本 ----------
cat > "$OUT/tile-state.py" <<'PYEOF'
# 读 com.apple.dock，报告测试 tile 是否在列、是否有 GUID、mod-count 与文件 mtime。
# 判断"Dock 是否真的读取并应用了我们的写入"的关键信号：Dock 应用后会给 tile 补 GUID。
import plistlib, sys, os, subprocess, time
label = sys.argv[1]
path = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")
out = subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True)
d = plistlib.loads(out.stdout)
apps = d.get("persistent-apps", [])
found = None
for t in apps:
    td = t.get("tile-data", {})
    if td.get("file-label") == label:
        found = t
        break
if found is None:
    state = "tile=ABSENT"
else:
    guid = found.get("GUID")
    state = "tile=PRESENT guid=%s" % ("yes" if guid else "no")
mtime = os.path.getmtime(path) if os.path.exists(path) else 0
print("%s apps=%d tilesize=%s mod-count=%s mtime=%.0f" % (
    state, len(apps), d.get("tilesize"), d.get("mod-count"), mtime))
PYEOF

cat > "$OUT/make-modified.py" <<'PYEOF'
# 基于当前全量域，生成"插入测试 tile"与"改 tilesize"两个变体 plist。
import plistlib, sys
src, dst_tile, dst_size, label, app_path, tilesize = sys.argv[1:7]
d = plistlib.load(open(src, "rb"))
apps = list(d.get("persistent-apps", []))
apps.append({
    "tile-type": "file-tile",
    "tile-data": {
        "file-data": {"_CFURLString": "file://" + app_path + "/", "_CFURLStringType": 15},
        "file-label": label,
        "dock-extra": 0,
        "file-type": 41,
    },
})
d["persistent-apps"] = apps
plistlib.dump(d, open(dst_tile, "wb"))
d2 = plistlib.load(open(src, "rb"))
d2["tilesize"] = float(tilesize)
plistlib.dump(d2, open(dst_size, "wb"))
print("生成完成：%s / %s" % (dst_tile, dst_size))
PYEOF

"$PYTHON" "$OUT/make-modified.py" "$BASELINE" "$OUT/mod-tile.plist" "$OUT/mod-size.plist" \
  "$TEST_LABEL" "$TEST_APP" "$TEST_TILESIZE" | tee -a "$SUMMARY"
log ""

if [[ "$DRY_RUN" == "1" ]]; then
  log "--dry-run：已生成 $OUT/mod-tile.plist 与 $OUT/mod-size.plist，未改动任何偏好。"
  exit 0
fi

# ---------- 实验主体 ----------
run_round() {  # run_round <轮次名> <要导入的 plist> <断言说明>
  local name="$1" plist="$2" desc="$3"
  log ""
  log "──── 轮次 [$name]：$desc ────"

  local pid_before; pid_before="$(dock_pid)"
  note "触发前 Dock PID = $pid_before"
  probe "$name-0-before"

  # --- T0：只写偏好 ---
  defaults import "$DOCK_DOMAIN" "$plist"
  note "T0 已写入偏好（未做任何触发）"
  sleep "$WAIT_SETTLE"
  probe "$name-1-T0-writeonly"
  shot  "$name-1-T0-writeonly"

  # --- A：分布式 / darwin 通知 ---
  notifyutil -p "com.apple.dock.prefchanged" 2>/dev/null
  notifyutil -p "AppleNoRedisplayAppearancePreferenceChanged" 2>/dev/null
  note "A  已 post 通知 com.apple.dock.prefchanged + AppleNoRedisplayAppearancePreferenceChanged"
  sleep "$WAIT_SETTLE"
  probe "$name-2-A-notify"
  shot  "$name-2-A-notify"

  # --- B：SIGHUP ---
  local pid_b; pid_b="$(dock_pid)"
  if [[ -n "$pid_b" ]]; then kill -HUP "$pid_b" 2>/dev/null; fi
  note "B  已 kill -HUP $pid_b"
  sleep "$WAIT_SETTLE"
  probe "$name-3-B-sighup"
  shot  "$name-3-B-sighup"

  # --- C：SIGTERM + kickstart ---
  local pid_c; pid_c="$(dock_pid)"
  if [[ -n "$pid_c" ]]; then kill -TERM "$pid_c" 2>/dev/null; fi
  note "C  已 kill -TERM $pid_c"
  local waited=0
  while [[ $waited -lt $WAIT_DOCK_BACK ]]; do
    sleep 1; waited=$((waited+1))
    [[ -n "$(dock_pid)" ]] && break
  done
  if [[ -z "$(dock_pid)" ]]; then
    note "C  Dock 未自动回归，执行 launchctl kickstart -k $DOCK_AGENT"
    launchctl kickstart -k "$DOCK_AGENT" >/dev/null 2>&1
    sleep 2
  fi
  note "C  Dock 归位用时约 ${waited}s，当前 PID = $(dock_pid)"
  sleep "$WAIT_SETTLE"
  probe "$name-4-C-restart"
  shot  "$name-4-C-restart"
}

run_round "tile" "$OUT/mod-tile.plist" "persistent-apps 增删一个图标（追加 $TEST_LABEL）"
run_round "size" "$OUT/mod-size.plist" "外观键 tilesize 36 → $TEST_TILESIZE"

log ""
log "=== 实验结束 ==="
log "截图：$OUT/shot-*.png"
log "探测：$OUT/probe-*.txt"
log "下一步：人工查看截图与 probe 输出，把结论写进 docs/spikes.md"
