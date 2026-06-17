# XGhostty GitHub Release 自动化

> 把 XGhostty 私有构建发布到本 fork(`NianDUI/ghostty`)的 Releases。
> 与上游 ghostty-org 的发布流水线**完全独立**。两条发版路径(产物/body 完全一致):
> **本地脚本**(免 runner,推荐日常)或 **CI**(push tag 自动,需 self-hosted runner 常驻)。
>
> 实现文件:
> - `scripts/xghostty-release.sh` —— 本地一键发版(CI 等价物,免 runner 常驻)
> - `scripts/xghostty-compose-release-body.sh` —— CI 与本地**共用**的 body 组装(DRY)
> - `.github/workflows/xghostty-release.yml` —— CI 流水线(push tag 自动,需 runner)
> - `.github/xghostty-release-body.md` —— release body 固定段(解隔离指引)
> - 本机 `~/actions-runner/` —— self-hosted runner(仅 CI 路径需要)

---

## 0. 目标与边界

- **只发 XGhostty**,不碰主 Ghostty(主 Ghostty 走上游官方流水线)。
- 触发:推送 `xghostty-vX.Y.Z` 形式的 tag。
- 产物:`XGhostty-X.Y.Z-macos-arm64.dmg`(Dev Cert 签名、**未公证**)。
- 不复用上游 `release-tag.yml` / `release-tip.yml` / `publish-tag.yml`——它们绑死
  Namespace runner + nix + cachix + Sparkle + R2 + 公证 secrets,我们一样都没有。

## 1. 关键设计决策(附理由)

| 决策 | 取值 | 理由 |
|---|---|---|
| 发版方式 | **本地脚本 + CI 双路径** | 本地脚本免 runner 常驻(日常推荐);CI 适合愿常驻 runner 时 push 即自动。两条 body/产物一致 |
| Runner | **self-hosted 本机**(仅 CI 路径) | Xcode 26 / zig / **Ghostty Dev Cert** 全现成,零 secrets;**本地脚本路径不需要 runner**;GitHub 托管 macOS runner 缺 Dev Cert、私有 repo 计费 10x、Xcode/Metal 不确定 |
| tag 前缀 | **`xghostty-v[0-9]+.[0-9]+.[0-9]+`** | 上游触发是纯 `v[0-9]+.[0-9]+.[0-9]+`,加前缀**互不触发** |
| 构建目标 | **`xcodebuild -target XGhostty`**(非 `-scheme`) | XGhostty scheme 在 xcuserdata、**未提交 git**,CI checkout 后没有;`-target` 绕开,且产物固定落 `macos/build/ReleaseLocal/`(无需 glob DerivedData) |
| 签名 | 构建即签(`CODE_SIGN_IDENTITY = Ghostty Dev Cert`, Manual) | xcodebuild 一次签好,**绝不事后改 bundle**(改 plist/重签会破坏签名 → SIGKILL) |
| 版本注入 | 构建时传 build setting | `GENERATE_INFOPLIST_FILE=YES`,`MARKETING_VERSION`→`CFBundleShortVersionString`、`CURRENT_PROJECT_VERSION`→`CFBundleVersion`,签名前写入,版本与 tag 一致且不破签名 |
| 核心版本 | `-Dversion-string=<build.zig.zon>` | 见踩坑③ |
| 打包 | `hdiutil` UDZO + `/Applications` 软链接 | 零依赖,带「拖进 Applications」 |
| 上传 | CI **softprops** / 本地 **`gh release create`**(均需 HTTPS_PROXY 补齐) | 见踩坑④⑤ |

**三条版本线**(互相独立,别混):
1. ghostty 核心 `build.zig.zon` = `1.3.2-dev`(跟随上游)
2. XGhostty 产品版本 = release tag 解析出的 `0.1.0`(注入 app)
3. CFBundleVersion = build 号(CI 用 `github.run_number` / 本地用 `git rev-list --count HEAD`,均单调递增)

## 2. 一次性搭建:注册 self-hosted runner(仅 CI 路径需要,本地脚本跳过本节)

1. GitHub → `NianDUI/ghostty` → **Settings → Actions → Runners**(左栏 Actions 是
   折叠分组,要先点开)→ New self-hosted runner → macOS。或用 `gh` 直接拿 token:
   ```
   gh api -X POST repos/NianDUI/ghostty/actions/runners/registration-token --jq .token
   ```
2. 已注册的 runner:`liyongdadeMacBook-Pro-xghostty`,labels `[self-hosted, macOS, ARM64]`
   (与 workflow `runs-on` 完全匹配)。
3. **⚠️ 启动方式硬约束**:`run.sh` **必须跑在登录会话**里(前台 `./run.sh` 或用户级
   LaunchAgent)。**不能**用需 root 的 `svc.sh` / LaunchDaemon —— 否则 `codesign`
   取不到 login keychain 里的 `Ghostty Dev Cert`,签名失败/挂起。
4. **⚠️ 代理**:runner 进程要继承 `HTTP_PROXY` **和** `HTTPS_PROXY`(见踩坑④)。

## 3. 发版流程

打 tag 用 annotated tag 写更新说明(两条路径通用;`-m` 内容进 body 的「## 本次更新」):
```bash
git tag -a xghostty-v0.2.0 -m "新增 xxx" -m "修复 yyy"
```

**路径 A · 本地脚本(免 runner,推荐日常)**:
```bash
git push origin xghostty-v0.2.0                 # 推 tag(让 body 的 Full Changelog 链接可用)
scripts/xghostty-release.sh xghostty-v0.2.0     # 构建→dmg→组 body→gh release create
```

**路径 B · CI(push tag 自动,需 runner 在线)**:
```bash
git push origin xghostty-v0.2.0                 # runner 在线则自动构建发布
```

两条同口径:`zig ReleaseFast`(传 `-Dversion-string`)→ `xcodebuild -target XGhostty`
(注入版本 + Dev Cert 签名)→ 验证 → `hdiutil` dmg → **共享脚本组 body** → 上传。
**release body 五段**(共享 `scripts/xghostty-compose-release-body.sh`,见 §3.1)。

- 构建 ~4 分钟;**上传 30M 经代理 3~35 分钟**(看实时带宽,见踩坑⑤),CI `timeout-minutes: 90`。

### 3.1 release body 五段结构(CI 与本地共用)

```
> 基于 ghostty <内核版本>      —— 读 build.zig.zon,零维护跟随上游
## 本次更新                     —— annotated tag 的 -m(无则跳过,不误取 commit message)
<固定解隔离说明>                —— .github/xghostty-release-body.md
## 校验  SHA-256               —— 算 dmg 真实哈希,下载者可校验
**Full Changelog**            —— commits 链接(手动生成,不依赖 GitHub 自动 notes)
```

## 4. 踩坑实录(都是 CI/异机特有,本地 deploy 永远遇不到)

### ① XGhostty scheme 未提交 → 用 `-target`
`xcshareddata/xcschemes/` 只有 `Ghostty.xcscheme`,XGhostty scheme 在 xcuserdata,
git 不跟踪。CI checkout 后 `-scheme XGhostty` 找不到。改用 `-target XGhostty`。

### ② job 级 env 用 `runner` context → startup_failure(0 秒)
```yaml
env:
  ZIG_GLOBAL_CACHE_DIR: ${{ runner.tool_cache }}/...   # ❌ runner context 在 job 级 env 不可用
```
GitHub schema 校验直接拒绝,run 显示 0s failure、名字是文件路径而非 workflow name。
**本地 YAML 解析不出来**(纯 YAML 合法,是 GitHub schema 层问题)。删掉即可,zig 走
默认缓存 `~/.cache/zig`(self-hosted 上跨 run 持久)。

### ③ CI checkout tag → ghostty build panic
```
thread panic: tagged releases must be in vX.Y.Z format matching build.zig
```
`src/build/Config.zig:268-278`:检测到 HEAD 落在 git tag 上就当「正式 release」,要求
tag 为 `vX.Y.Z` 且匹配 `build.zig.zon`;`xghostty-v0.1.0` 不符 → panic。
**修复**:`Config.zig:240` —— 传 `-Dversion-string=<v>` 走显式版本分支,**完全跳过**
git tag 检测。值取 `build.zig.zon` 的版本(`SemanticVersion.parse` 接受 `1.3.2-dev`):
```bash
ZIG_VER=$(grep -m1 '\.version' build.zig.zon | sed -E 's/.*"([^"]+)".*/\1/')
zig build ... -Dversion-string="$ZIG_VER"
```
> 本地 `xghostty-deploy.sh` 在 main 分支某 commit 构建,HEAD 不在 tag 上,故从不触发。

### ④ softprops 上传卡死 → 补 `HTTPS_PROXY`(根因是没走代理,非 octokit timeout)
softprops/action-gh-release 是 node action,用 octokit 上传,走 **`HTTPS_PROXY`**。
self-hosted runner 环境可能只有 `HTTP_PROXY` 没 `HTTPS_PROXY` → octokit 对 https
不走代理、直连 GitHub 传大文件**卡死**(创建 release 的小请求侥幸通了,传 30M dmg 卡)。
**修复**:Publish 前一步从 `HTTP_PROXY` 补齐 `HTTPS_PROXY` 写进 `$GITHUB_ENV`。
**已验证**:独立测试 workflow 推 2M 小文件,补齐后 softprops 走代理 **71s 传成**(success);
确认根因是缺 proxy、而非 octokit 内部 timeout,故 CI **保留 softprops**;body 改由共享脚本
`xghostty-compose-release-body.sh` 组装(含手动 Full Changelog,不再用 `generate_release_notes`)。
手动应急仍可用 `gh release upload`(见 §5)。

### ⑤ 经代理上传 GitHub 极慢(30M / 35 分钟)
本机经代理上传 GitHub 出口带宽 ≈14KB/s,30M dmg 实测 **35 分钟**。这是带宽瓶颈,
非 workflow bug。`timeout-minutes` 提到 **90** 留余量。首发 v0.1.0 即是手动
`gh release upload`(35min)补传完成的。

### ⑥ 上游 Test/Nix 被 xghostty tag 误触发(噪音,未根治)
push `xghostty-v*` tag 会连带触发上游 `Test`/`Nix`(它们 on: push 含 tags),在
GitHub 上排队等我们没有的 runner,空挂到超时。目前手动 `gh run cancel` 清理。
**待根治**:给上游 workflow 加 tag 过滤,或在 repo 设置禁用它们。

## 5. 运维 / 排查手册(CI 路径)

> 本地脚本路径直接看终端输出排查,无需以下 `gh run` 命令。

```bash
# 看最近 run(注意 -R 指向 fork,否则 gh 多 remote 会解析到 ghostty-org 上游)
gh run list -R NianDUI/ghostty -L 6
gh run view --job=<jobId> -R NianDUI/ghostty        # 各 step ✓/✗/*
gh run view <runId> -R NianDUI/ghostty --log-failed  # 失败 step 日志
gh api repos/NianDUI/ghostty/actions/jobs/<jobId> \
  --jq '.steps[]|"\(.status)\t\(.name)\tstart=\(.started_at)"'  # 各 step 耗时

# runner 状态
gh api repos/NianDUI/ghostty/actions/runners --jq '.runners[]|{name,status,busy}'

# 卡住时:取消 run,产物仍在 runner workspace,可本机手动补传
gh run cancel <runId> -R NianDUI/ghostty
ls -lh ~/actions-runner/_work/ghostty/ghostty/XGhostty-*.dmg
gh release upload <tag> <dmg> -R NianDUI/ghostty --clobber   # 本机 gh 走代理
gh release edit <tag> -R NianDUI/ghostty --draft=false        # 发布(去 draft)
```

## 6. 已知限制 / 待办

- **上传慢(~35min)**:代理出口带宽瓶颈。可考虑换分发渠道(自有服务器 47.94.215.160)。
- **上游 CI 噪音**:每次推 tag 触发上游 Test/Nix,需手动取消(踩坑⑥待根治)。
- **未公证**:Dev Cert 签名,异机下载需「仍要打开」或 `xattr` 解隔离(见 release body)。
- **remote main 未同步**:workflow commit 目前只在本地,靠 push tag 带上;若要 remote
  main 也有,需 `git push origin main`(但会触发上游 CI 噪音)。
