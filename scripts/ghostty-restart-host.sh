#!/usr/bin/env bash
#
# ghostty-restart-host.sh — 重启正在运行的 Ghostty（默认主 Ghostty，可能是 Claude Code 宿主）
#
# 为什么单独固化成脚本（踩坑固化，2026-06 一次"鬼窗口"事故）：
#   重启宿主这件事 xghostty-deploy.sh 故意不做（对主 Ghostty/宿主只原子替换 + 提示手动重启），
#   于是每次都临时手搓 daemon —— 结果某次手搓的 daemon 发了 SIGTERM 而不是 kill -9。SIGTERM
#   退得慢，open 抢在旧实例还没退干净时就起了新实例，macOS 窗口状态恢复撞出"鬼窗口"（显示上次
#   界面但点不动、连不上 pty，关掉重开才好）。把唯一正确姿势固化在这里，杜绝再漂移：
#     · kill -9（不是 SIGTERM）：毫秒级清场，open 干净起单实例，不触发半死的恢复窗口
#     · kill -9（不是 osascript … quit）：多 tab 时 quit 会弹"确认退出"卡死自动化
#     · sleep 2：给旧实例彻底退出 + 释放单实例锁/落盘 savedState 留足时间
#     · 重启动作 nohup + disown 完全脱离宿主进程树：宿主被 -9 杀掉也不会把它一起带走
#       （父 shell 随 ghostty 一起死后，sleep 子进程被 launchd 收养，2 秒后才 open）
#     · 进程匹配前导 "/" 锚定：'Ghostty.app' 是 'XGhostty.app' 的子串，不锚定会误吃 XGhostty
#
# 用法:
#   scripts/ghostty-restart-host.sh [Ghostty.app|XGhostty.app] [-y]
#     第 1 参：app 名，默认 Ghostty.app（主 Ghostty）；也可传 XGhostty.app
#     -y / --yes：跳过确认，直接重启（自动化 / Claude Code 自愈重启用）
#
# ⚠ 若本脚本跑在目标 app 的子 shell 里（典型：Claude Code 宿主就在主 Ghostty 内），kill -9 会
#   顺带结束当前会话 —— 这是预期行为，已脱离的重启子进程会在 2 秒后把 app 拉回来。
#
# XGhostty（传 XGhostty.app）特例 —— 比主 Ghostty 更省心，但有一处取舍：
#   · 不是 Claude Code 宿主：杀它不结束本会话；上面 nohup/disown 脱离逻辑对它属无害冗余。
#   · 不吃 macOS 窗口恢复：XGhostty 走自己的 LayoutStore(~/.config/xghostty/layout.json) 恢复
#     会话树，故"SIGTERM 抢跑 → 鬼窗口"那个坑对它基本不适用。
#   · kill -9 跳过 XGhostty 退出时的 save()：正常无碍（改动即时落盘）；只有刚改了还没落盘的
#     内存态（拖布局/改会话树未触发 save）会丢这一小段。反之"改 ~/.config/xghostty/*.json 前
#     先 kill 防 save() 覆盖"正需要这个跳过效果。
#
# 注意：不用 set -e。kill 掉宿主会连带杀掉本脚本自身，那不该被当成"错误退出"。
set -uo pipefail

# ── 日志 ──
info() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 参数 ──
APP_NAME="Ghostty.app"
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    Ghostty.app|XGhostty.app) APP_NAME="$a" ;;
    -y|--yes)                 ASSUME_YES=1 ;;
    -h|--help)
      # 只打印文件顶部说明块（到 set -uo pipefail 为止），不含后面的小节注释
      sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/d; s/^# \{0,1\}//; p;}' "$0"; exit 0 ;;
    *) die "未知参数：$a（用法见 -h）" ;;
  esac
done
APP="/Applications/$APP_NAME"
[ -d "$APP" ] || die "找不到 $APP"

# ── 找运行中的实例 PID（前导 "/" 锚定，排除 XGhostty 子串误吃；与 xghostty-deploy.sh 同一套）──
pid="$(ps -A -o pid,comm | awk -v a="$APP_NAME" 'index($0, "/" a"/Contents/MacOS/ghostty") {print $1}' | head -1)"

if [ -z "$pid" ]; then
  info "$APP_NAME 未在运行 → 直接 open"
  open "$APP"
  ok "已启动 $APP_NAME"
  exit 0
fi

# ── 是否本会话宿主（仅用于给用户更准的提示，不改变"杀"的决定——重启宿主就是本脚本的目的）──
host_note=""
p=$$
while [ "$p" -gt 1 ]; do
  if [ "$p" = "$pid" ]; then host_note="（含当前 Claude Code/终端宿主，本会话将被结束）"; break; fi
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -z "$p" ] && break
done

warn "将 kill -9 $APP_NAME（PID $pid）$host_note，2 秒后自动 open 拉回。"
if [ "$ASSUME_YES" != 1 ]; then
  if [ -t 0 ]; then
    read -r -p "继续? [y/N] " ans
    case "$ans" in y|Y|yes|YES) ;; *) info "已取消。"; exit 0 ;; esac
  else
    die "非交互环境必须带 -y/--yes 才会执行（防误杀）。"
  fi
fi

# ── 先把"脱离宿主进程树"的重启子进程调度好，再 kill —— 顺序不能反 ──
# nohup 忽略 SIGHUP + disown 解绑当前 shell：宿主被杀后 sleep 子进程被 launchd 收养，到点 open。
nohup bash -c "sleep 2 && open '$APP'" >/dev/null 2>&1 &
disown
info "重启子进程已脱离宿主调度（2 秒后 open $APP）"

# 给后台子进程一点起步时间，再清场
sleep 0.3
info "kill -9 $pid"
kill -9 "$pid"

# 走到这里通常意味着被杀的不是本脚本的宿主；若是宿主，脚本已随之终止，下面不会执行。
ok "已发送 kill -9，等待重启子进程在 2 秒后拉回 $APP_NAME。"
