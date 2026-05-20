# macOS — Release 构建补遗

补根 `CLAUDE.md` 的 "Key Conventions" 段。根里已经写过的（ReleaseFast、
codesign 必须、xcframework 重建条件）不重复。

## 产物路径

xcodebuild Release `.app` 落在 **DerivedData**（不是 `zig-out`）：

```
~/Library/Developer/Xcode/DerivedData/Ghostty-<hash>/Build/Products/ReleaseLocal/Ghostty.app
```

`<hash>` 由 (机器 + .xcodeproj) 派生，跨机器不同。脚本里用 glob
`Ghostty-*` 或 `xcodebuild -showBuildSettings | grep TARGET_BUILD_DIR`
取，**不要 hard-code**。

## 完整 Release 流水线

`/Applications` 是 `drwxrwxr-x root:admin`，admin 组成员可写；已有
bundle 的 owner 是当前用户。先 sign 再 cp 避免触发 Gatekeeper 缓存抖动。

```bash
# 1. Zig ReleaseFast（耗时 3-5 分钟，可后台）
zig build -Doptimize=ReleaseFast -Demit-macos-app=false

# 2. xcodebuild Release
xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty \
           -configuration ReleaseLocal -destination 'generic/platform=macOS' build

# 3. 签 + 装（不 sudo）
APP=$(find ~/Library/Developer/Xcode/DerivedData/Ghostty-*/Build/Products/ReleaseLocal/Ghostty.app -maxdepth 0 | head -1)
codesign --force --deep --sign - "$APP"
rm -rf /Applications/Ghostty.app && cp -R "$APP" /Applications/
codesign -dv /Applications/Ghostty.app   # universal + adhoc
```

## SwiftLint `force_try` 是 build error

测试里**禁用 `try!`**。用 `try? + guard … else { Issue.record(); continue }`。
其他 SwiftLint warning 只是警告，不阻塞。

## 三类噪音输出，过滤掉

只看 `error:` / `BUILD FAILED` / `failed on`。以下都忽略：

- `SourceKit: No such module 'GhosttyKit'` — IDE 静态分析，xcodebuild 不受影响
- `iOSSimulator: CoreSimulator is out of date` — 只影响 iOS destination
- `xcodebuild: TEST FAILED` ≠ 全失败，意为「至少一个」，`grep "failed on"` 找具体哪个

## Sanity 标尺

ReleaseFast 二进制 ~50 MiB；> 100 MiB 说明 zig 用了 Debug 没 Release。

## 从 Claude Code 内 kill 并自动重启 Ghostty

Claude Code 跑在 Ghostty 子 shell 里，直接 `kill` ghostty 会顺带杀掉
自己；**reopen 必须先调度好再 kill**，否则没人替你拉回来。

```bash
PID=$(ps -A -o pid,comm | awk '/Ghostty.app\/Contents\/MacOS\/ghostty/ {print $1}' | head -1)
nohup bash -c 'sleep 2 && open /Applications/Ghostty.app' >/dev/null 2>&1 &
disown
kill -9 "$PID"
```

- `nohup` 让子 shell 忽略 SIGHUP；`disown` 解绑当前 shell。父 shell
  随 ghostty 一起死后，sleep 子进程被 launchd 收养，2 秒后调 `open`。
- `pgrep -x ghostty` 不 work —— 主进程的 comm 是绝对路径
  `/Applications/Ghostty.app/Contents/MacOS/ghostty`。用 `ps + awk`
  或 `pgrep -lf "Ghostty.app"` 再过滤。
- 用 `kill -9` 而不是 `osascript … quit`：quit 会触发"是否真的退出？"
  的窗口列表确认弹窗（如果开了多个 tab），自动化场景下挂死。
- ❌ 不要省掉 `nohup`/`disown`：父 shell 收到 SIGHUP 会把 sleep 一起
  带走，`open` 永远不跑。
