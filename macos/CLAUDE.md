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
