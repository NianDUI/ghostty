XGhostty 私有构建（ReleaseFast，Ghostty Dev Cert 签名，**未公证**）。

首次打开若被 Gatekeeper 拦截（"身份不明的开发者"），二选一放行（只需一次）：

**方式一 · GUI（推荐）**：双击被拦 → 系统设置 →「隐私与安全性」→ 下滑到「安全性」→ 点「仍要打开」→ Touch ID/密码 → 再双击点「打开」。

**方式二 · 命令行兜底**：若报"已损坏"导致设置页没有「仍要打开」，则解隔离：

```
xattr -dr com.apple.quarantine /Applications/XGhostty.app
```

注：右键打开在 macOS 15+ 已失效，请用上面两种方式。
