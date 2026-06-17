#!/usr/bin/env bash
# XGhostty 本地一键发版 —— CI workflow 的本地等价物,不需 self-hosted runner 常驻。
# 构建 dmg → 组装 body(共享脚本)→ gh release create 上传发布。
#
# 用法:
#   git tag -a xghostty-v0.2.0 -m "更新内容"   # annotated tag,-m 写本次更新(可多个 -m 分段)
#   git push origin xghostty-v0.2.0
#   scripts/xghostty-release.sh xghostty-v0.2.0
# 忘了 -m(或打 lightweight tag)也能发,只是 body 没有「本次更新」段,不会误取 commit message。
#
# 与 .github/workflows/xghostty-release.yml 同口径:zig ReleaseFast(传 -Dversion-string)
# → xcodebuild -target XGhostty(注入版本 + Dev Cert 签名,绝不事后改 bundle)→ 验证 →
# hdiutil dmg → 共享脚本组 body → gh release create。
set -euo pipefail
TAG="${1:?用法: xghostty-release.sh <tag,如 xghostty-v0.2.0>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO="NianDUI/ghostty"
VER="${TAG#xghostty-v}"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

bold "==[1] zig 核心(ReleaseFast,-Dversion-string 跳过 tagged-release 检测)=="
ZIG_VER="$(grep -m1 '\.version' build.zig.zon | sed -E 's/.*"([^"]+)".*/\1/')"
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dversion-string="$ZIG_VER"

bold "==[2] xcodebuild XGhostty(注入版本 + Dev Cert 签名)=="
( cd macos && xcodebuild -project Ghostty.xcodeproj -target XGhostty -configuration ReleaseLocal \
    MARKETING_VERSION="$VER" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" build )
APP="macos/build/ReleaseLocal/XGhostty.app"
[ -d "$APP" ] || die "产物未找到: $APP"

bold "==[3] 验证(签名/可启动/ReleaseFast/版本一致)=="
# 先捕获 codesign 输出再 grep —— 直接 `codesign | grep -q` 会让 grep 一命中就退出、
# codesign 收 SIGPIPE,在 set -o pipefail 下令整条管道非 0(偶发误判"签名非 Dev Cert")。
CS="$(codesign -dvv "$APP" 2>&1)"
printf '%s' "$CS" | grep -q "Ghostty Dev Cert" || die "签名非 Ghostty Dev Cert"
"$APP/Contents/MacOS/ghostty" +version >/tmp/xg_rel_ver 2>&1 || die "+version 退出码非 0(签名无效会 SIGKILL)"
grep -qi ReleaseFast /tmp/xg_rel_ver || echo "  ⚠ build mode 非 ReleaseFast,留意是否 Debug"
PV="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[ "$PV" = "$VER" ] || die "app 版本($PV) ≠ tag 版本($VER)"
ok "验证通过 | 版本 $PV | $(printf '%s' "$CS" | grep -i '^Authority=' | head -1)"

bold "==[4] hdiutil dmg(带「拖进 Applications」软链接)=="
mkdir -p dist
DMG="dist/XGhostty-${VER}-macos-arm64.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/XGhostty.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "XGhostty $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
ok "dmg = $DMG ($(du -h "$DMG" | awk '{print $1}'))"

bold "==[5] 组装 body(共享脚本:内核版本 + 本次更新 + 解隔离说明 + SHA-256)=="
NOTES="$(mktemp)"
bash scripts/xghostty-compose-release-body.sh "$TAG" "$DMG" "$REPO" > "$NOTES"
echo "----- 预览 -----"; cat "$NOTES"; echo "----------------"

bold "==[6] gh release create $TAG(走代理上传,30M 视带宽 3~35min)=="
# 本机 shell 一般已有 HTTPS_PROXY;兜底从 HTTP_PROXY 补齐,否则 gh 传大文件直连卡死
export HTTPS_PROXY="${HTTPS_PROXY:-${HTTP_PROXY:-}}"
gh release create "$TAG" "$DMG" --title "$TAG" --notes-file "$NOTES" --latest -R "$REPO"
ok "发布完成: https://github.com/$REPO/releases/tag/$TAG"
