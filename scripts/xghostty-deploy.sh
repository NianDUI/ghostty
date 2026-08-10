#!/usr/bin/env bash
#
# xghostty-deploy.sh — 构建 + 替换 XGhostty / 主 Ghostty 正式版(ReleaseFast)到 /Applications
#
# 把这套「踩过坑、反着来就 SIGKILL / 白构建」的规则固化成一条命令：
#   · 签名两套规则：XGhostty(Ghostty Dev Cert)绝不重签；主 Ghostty(adhoc)必须 --force --deep 重签
#   · 按需重跑 zig：src/ 有 .zig 比 xcframework 新才重跑 ReleaseFast，否则复用(省 3-5 分钟)
#   · 产物在 DerivedData 的 hash 目录(glob，不 hard-code)
#   · 原子替换(cp .new → rm 旧 → mv)；主 Ghostty / 当前终端宿主不 kill、其余可 kill 重启
#   · 每步验证：+version 退出码 0(没被 SIGKILL) + .ReleaseFast + 签名 Authority
#
# 用法:
#   scripts/xghostty-deploy.sh [xghostty|ghostty|both]   # 不带参数则交互选
#   选项:
#     --core         强制重跑 zig ReleaseFast(忽略自动检测)
#     --skip-core    强制跳过 zig(直接复用现有 xcframework)
#     --build-only   只构建+验证，不替换 /Applications(测试用)
#     --yes, -y      替换前不询问，直接替换(自动化用)
#
set -euo pipefail

# ── 路径 ──
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
XCFW="$REPO/macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"
PROJ="$REPO/macos/Ghostty.xcodeproj"

# ── 日志 ──
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
xghostty-deploy.sh — 构建 + 替换 XGhostty / 主 Ghostty 正式版(ReleaseFast)到 /Applications

用法:
  scripts/xghostty-deploy.sh [target] [选项]

target（不带则交互选）:
  xghostty      只 XGhostty
  ghostty       只主 Ghostty
  both          两个都要

选项:
  --core        强制重跑 zig ReleaseFast（忽略自动检测）
  --skip-core   强制跳过 zig，直接复用现有 xcframework
  --build-only  只构建+验证，不替换 /Applications（测试用）
  --yes, -y     替换前不询问，直接替换（自动化用）
  -h, --help    显示本帮助并退出

行为:
  · Zig 按需重跑：src/*.zig 比 xcframework 新才重跑，否则复用（省 3-5 分钟）
  · 签名两套规则：XGhostty(Dev Cert)绝不重签 / 主 Ghostty(adhoc)必重签
  · 构建+验证全过后才询问是否替换；原子替换；当前终端宿主 / 主 Ghostty 一律不 kill
  · 每步验证 +version 退出码 0（没 SIGKILL）+ .ReleaseFast + 签名 Authority

示例:
  scripts/xghostty-deploy.sh                        # 交互选
  scripts/xghostty-deploy.sh xghostty               # 出 XGhostty 正式版并询问替换
  scripts/xghostty-deploy.sh both --core            # 强制重跑 zig，两个都出
  scripts/xghostty-deploy.sh xghostty --build-only  # 只构建验证、不替换
EOF
}

# ── 参数解析 ──
CORE_MODE=auto          # auto | force | skip
BUILD_ONLY=0
ASSUME_YES=0
TARGETS=()
for a in "$@"; do
  case "$a" in
    xghostty|ghostty)  TARGETS+=("$a") ;;
    both)              TARGETS=(ghostty xghostty) ;;
    --core)            CORE_MODE=force ;;
    --skip-core)       CORE_MODE=skip ;;
    --build-only)      BUILD_ONLY=1 ;;
    --yes|-y)          ASSUME_YES=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "未知参数: ${a}（用 xghostty|ghostty|both 加可选 --core/--skip-core/--build-only/--yes；-h 看帮助）" ;;
  esac
done

# 不带 target → 交互选
if [ ${#TARGETS[@]} -eq 0 ]; then
  bold "选择要构建/替换的目标:"
  select _ in "XGhostty" "主 Ghostty" "两个都要"; do
    case "${REPLY:-}" in
      1) TARGETS=(xghostty); break ;;
      2) TARGETS=(ghostty); break ;;
      3) TARGETS=(ghostty xghostty); break ;;
      *) warn "请输入 1 / 2 / 3" ;;
    esac
  done
fi
info "目标: ${TARGETS[*]}"

# ── target 元数据 ──
target_scheme() { case "$1" in xghostty) echo XGhostty;; ghostty) echo Ghostty;; esac; }
target_app()    { case "$1" in xghostty) echo XGhostty.app;; ghostty) echo Ghostty.app;; esac; }
target_resign() { case "$1" in xghostty) echo no;; ghostty) echo yes;; esac; }   # XGhostty 绝不重签
target_name()   { case "$1" in xghostty) echo "XGhostty";; ghostty) echo "主 Ghostty";; esac; }

# 产物路径暂存：macOS 自带 bash 3.2 无关联数组，用 eval 间接变量（target 名仅 xghostty/ghostty，是合法变量名）
built_set() { eval "BUILT_${1}=\"\$2\""; }
built_get() { eval "printf '%s' \"\${BUILT_${1}:-}\""; }

# ── 1. 决定要不要重跑 zig ──
need_core() {
  [ -f "$XCFW" ] || { info "xcframework 不存在 → 需重跑 zig"; return 0; }
  # src/ 任意 .zig 比 xcframework 新 → stale
  local newer
  newer="$(find "$REPO/src" -name '*.zig' -newer "$XCFW" -print -quit 2>/dev/null || true)"
  if [ -n "$newer" ]; then
    info "src/ 有文件比 xcframework 新(如 ${newer#"$REPO"/}) → 需重跑 zig"; return 0
  fi
  # 构建配置/依赖清单变更也要重建
  if [ "$REPO/build.zig" -nt "$XCFW" ] || [ "$REPO/build.zig.zon" -nt "$XCFW" ]; then
    info "build.zig(.zon) 比 xcframework 新 → 需重跑 zig"; return 0
  fi
  return 1
}

run_zig() {
  info "zig build -Doptimize=ReleaseFast -Demit-macos-app=false（3-5 分钟）…"
  zig build -Doptimize=ReleaseFast -Demit-macos-app=false
  ok "zig 核心已重建"
}

case "$CORE_MODE" in
  force) run_zig ;;
  skip)  warn "--skip-core：跳过 zig，复用现有 xcframework" ;;
  auto)
    if need_core; then
      run_zig
    else
      # 复用前 sanity：ReleaseFast 的 .a ~280MB，<200MB 多半是 Debug 混进来了
      mb=$(( $(stat -f%z "$XCFW") / 1024 / 1024 ))
      if [ "$mb" -lt 200 ]; then
        warn "现有 xcframework 仅 ${mb}MB（ReleaseFast 应 ~280MB）——疑似 Debug！建议加 --core 重跑。"
      else
        ok "复用现有 ReleaseFast xcframework（${mb}MB，src/ 未更新）"
      fi
    fi
    ;;
esac

# ── 2. 构建 + 验证（per target）──
build_target() {
  local t="$1" scheme app log p rc
  scheme="$(target_scheme "$t")"; app="$(target_app "$t")"
  bold "═══ 构建 $(target_name "$t")（scheme=$scheme, ReleaseLocal）═══"
  log="$(mktemp -t xgbuild)"
  set +e
  xcodebuild -project "$PROJ" -scheme "$scheme" \
    -configuration ReleaseLocal -destination 'generic/platform=macOS' build >"$log" 2>&1
  rc=$?
  set -e
  grep -E 'error:|BUILD (SUCCEEDED|FAILED)' "$log" | tail -8 || true
  [ "$rc" -eq 0 ] || { warn "完整日志: $log"; die "$(target_name "$t") 构建失败（exit ${rc}）"; }
  p="$(find ~/Library/Developer/Xcode/DerivedData/Ghostty-*/Build/Products/ReleaseLocal/"$app" -maxdepth 0 2>/dev/null | head -1)"
  [ -n "$p" ] && [ -d "$p" ] || die "$(target_name "$t") 产物未找到"
  built_set "$t" "$p"
  verify_app "$t" "$p"
}

verify_app() {
  local t="$1" app="$2" bin="$2/Contents/MacOS/ghostty" mb auth ver mode
  mb=$(( $(stat -f%z "$bin") / 1024 / 1024 ))
  { [ "$mb" -ge 40 ] && [ "$mb" -le 100 ]; } || warn "二进制 ${mb}MB 偏离 ~50MB(ReleaseFast)，留意是否 Debug"
  auth="$(codesign -dvv "$app" 2>&1 | grep -i '^Authority=' | head -1 || echo 'Authority=?')"
  if "$bin" +version >/tmp/.xgdeploy_ver 2>&1; then
    ver="$(grep -i 'version:' /tmp/.xgdeploy_ver | head -1 | xargs || true)"
    mode="$(grep -i 'build mode' /tmp/.xgdeploy_ver | head -1 | xargs || true)"
  else
    die "$(target_name "$t") +version 退出码非 0（签名无效会 SIGKILL）"
  fi
  echo "$mode" | grep -q ReleaseFast || warn "build mode 非 ReleaseFast：$mode"
  # 签名规则校验：XGhostty 必须是 Ghostty Dev Cert
  if [ "$t" = xghostty ]; then
    echo "$auth" | grep -q "Ghostty Dev Cert" || warn "XGhostty 签名非 Ghostty Dev Cert：$auth"
  fi
  ok "$(target_name "$t") 验证通过 | ${mb}MB | $auth | $mode"
}

for t in "${TARGETS[@]}"; do build_target "$t"; done

if [ "$BUILD_ONLY" = 1 ]; then
  bold "--build-only：构建+验证完成，未替换 /Applications。"
  for t in "${TARGETS[@]}"; do echo "  $(target_name "$t"): $(built_get "$t")"; done
  exit 0
fi

# ── 3. 询问是否替换 ──
if [ "$ASSUME_YES" != 1 ]; then
  bold "构建+验证全部通过。替换到 /Applications？"
  for t in "${TARGETS[@]}"; do echo "  → /Applications/$(target_app "$t")"; done
  read -r -p "替换? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) info "已取消替换。产物保留在 DerivedData。"; exit 0 ;; esac
fi

# ── 4. 替换（per target，套正确签名规则）──
pid_is_my_ancestor() {  # 当前 shell 祖先链里有 $1 则返回 0（避免 kill 掉自己的宿主终端）
  local p=$$
  while [ "$p" -gt 1 ]; do
    [ "$p" = "$1" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -z "$p" ] && break
  done
  return 1
}

replace_target() {
  local t="$1" app src dst pid
  app="$(target_app "$t")"; src="$(built_get "$t")"; dst="/Applications/$app"
  bold "═══ 替换 $(target_name "$t") → $dst ═══"

  # 签名：仅主 Ghostty(adhoc)重签；XGhostty(Dev Cert)绝不重签（重签会 SIGKILL）
  if [ "$(target_resign "$t")" = yes ]; then
    info "adhoc 重签（--force --deep --sign -）…"
    codesign --force --deep --sign - "$src"
  else
    info "XGhostty 已用 Ghostty Dev Cert 签名 → 不重签"
  fi

  # 退出运行实例（保护：宿主 / 主 Ghostty 不 kill，只原子替换 + 提示重启）
  # 前导 "/" 锚定：'Ghostty.app' 是 'XGhostty.app' 的子串，不加 "/" 会让主 Ghostty 的
  # 匹配吃进 XGhostty 进程（反之 XGhostty 不会吃主 Ghostty）。'/Ghostty.app/' 不是
  # '/XGhostty.app/' 的子串（后者 '/' 后是 'X'），加前导 "/" 即可精确消歧。
  pid="$(ps -A -o pid,comm | awk -v a="$app" 'index($0, "/" a"/Contents/MacOS/ghostty") {print $1}' | head -1)"
  if [ -n "$pid" ]; then
    if pid_is_my_ancestor "$pid"; then
      warn "$(target_name "$t")(PID $pid)是当前终端宿主 → 不 kill；原子替换 inode 保留，本会话不受影响，重启后生效。"
    elif [ "$t" = ghostty ]; then
      warn "主 Ghostty(PID $pid)运行中（可能是 Claude Code 宿主）→ 不 kill；原子替换，重启后生效。"
    else
      info "退出运行中的 $(target_name "$t")(PID $pid)…"; kill -9 "$pid"; sleep 1.5
    fi
  fi

  # 原子替换
  rm -rf "$dst.new"
  cp -R "$src" "$dst.new"
  rm -rf "$dst"
  mv "$dst.new" "$dst"
  ok "已替换 $dst"

  # 装后验证（退出码 0 = 签名有效）
  if "$dst/Contents/MacOS/ghostty" +version >/tmp/.xgdeploy_ver 2>&1; then
    ok "$(target_name "$t") 装后 +version OK：$(grep -i version: /tmp/.xgdeploy_ver | head -1 | xargs)"
  else
    die "$(target_name "$t") 装后 +version 失败（SIGKILL?）"
  fi

  # 重启：XGhostty 且非宿主才自动拉起；主 Ghostty / 宿主提示手动
  if [ "$t" = xghostty ] && { [ -z "$pid" ] || ! pid_is_my_ancestor "$pid"; }; then
    info "open $dst"; open "$dst"
  else
    warn "$(target_name "$t") 需手动重启生效：open $dst"
  fi
}

for t in "${TARGETS[@]}"; do replace_target "$t"; done
bold "全部完成。"
