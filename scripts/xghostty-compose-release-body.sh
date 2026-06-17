#!/usr/bin/env bash
# 组装 XGhostty release body —— CI workflow(.github/workflows/xghostty-release.yml)与
# 本地 scripts/xghostty-release.sh 共用,保证两条发版路径的 body 完全一致。
# 输出完整 body 到 stdout。
#
# 用法: xghostty-compose-release-body.sh <tag> <dmg-path> [repo-slug]
#
# body 结构(对齐 7zip docs/07-release.md 的 release.sh):
#   > 基于 ghostty <内核版本>     —— 读 build.zig.zon,零维护跟随上游
#   ## 本次更新                    —— annotated tag 的 -m 内容(无则跳过,不误取 commit message)
#   <固定解隔离说明>               —— .github/xghostty-release-body.md
#   ## 校验  SHA-256               —— 算 dmg 真实哈希,下载者可校验
#   **Full Changelog**            —— commits 链接(手动生成,不依赖 GitHub 自动 notes)
set -euo pipefail
TAG="${1:?用法: $0 <tag> <dmg> [repo]}"
DMG="${2:?需要 dmg 路径}"
REPO="${3:-NianDUI/ghostty}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 内核版本(上游 ghostty)——从 build.zig.zon 自动读,同步上游升级后自动跟变
CORE="$(grep -m1 '\.version' "$ROOT/build.zig.zon" | sed -E 's/.*"([^"]+)".*/\1/')"

# 本次更新——仅 annotated tag(cat-file 类型为 tag)才取 message;去掉可能的 PGP 签名段
MSG=""
if [ "$(git -C "$ROOT" cat-file -t "$TAG" 2>/dev/null)" = "tag" ]; then
  MSG="$(git -C "$ROOT" for-each-ref "refs/tags/$TAG" --format='%(contents)' | sed '/-----BEGIN PGP/,$d')"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

{
  [ -n "$CORE" ] && printf '> 基于 ghostty %s\n\n' "$CORE"
  if [ -n "$(printf '%s' "$MSG" | tr -d '[:space:]')" ]; then
    printf '## 本次更新\n\n%s\n\n' "$MSG"
  fi
  cat "$ROOT/.github/xghostty-release-body.md"
  printf '\n## 校验\nSHA-256 (`%s`):\n`%s`\n' "$(basename "$DMG")" "$SHA"
  printf '\n**Full Changelog**: https://github.com/%s/commits/%s\n' "$REPO" "$TAG"
}
