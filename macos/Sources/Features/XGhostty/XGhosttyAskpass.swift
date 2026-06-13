#if XGHOSTTY
import Foundation

/// SSH 密码自动登录的 `SSH_ASKPASS` 机制封装。
///
/// **原理**：ssh 在需要密码时会调用 `SSH_ASKPASS` 指向的程序、把密码从其 stdout 读走。
/// 默认仅在「无 tty」时才用 askpass；我们的 ssh 跑在 pty 里有 tty，故必须
/// `SSH_ASKPASS_REQUIRE=force` 强制启用（需 OpenSSH ≥ 8.4，macOS 15+ 自带 9.x）。
///
/// **密码投递**（不依赖 Keychain ACL，规避 ad-hoc 签名 churn）：控制器从 Keychain 取出
/// 密码 → 写一个 0600 临时文件 → 把路径经环境变量 `XGHOSTTY_ASKPASS_FILE` 传给脚本；
/// 脚本 `cat` 出来后**立即 `rm` 自删**（密码在盘上只存活到 ssh 读走的一瞬）。pubkey 先
/// 成功 → askpass 不被调用 → 由调用方 backstop 定时器兜底删除。
///
/// **host-key 安全**：必须配合 `StrictHostKeyChecking=accept-new`（见 SessionCommandBuilder），
/// 否则首连新主机的 `yes/no` 提示也会走 askpass、被当成密码答进去而连接失败。
enum XGhosttyAskpass {
    /// 一次连接的投递句柄：注入到 ssh 的环境变量 + 兜底清理闭包。
    struct Prepared {
        let environment: [String: String]
        let cleanup: () -> Void
    }

    /// 为一次连接准备 askpass：写好脚本（幂等）+ 落 0600 密码临时文件。
    /// 返回需要并入 `environmentVariables` 的键值 + 兜底清理闭包；失败返回 nil（降级到手输密码）。
    static func prepare(password: String) -> Prepared? {
        guard let script = ensureScript() else { return nil }
        guard let dir = baseDir() else { return nil }

        let file = dir.appendingPathComponent(UUID().uuidString, isDirectory: false)
        // 直接以 0600 创建（不经 write(atomically:)，避免中间临时文件的权限窗口）。
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: Data((password + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }

        let env: [String: String] = [
            "SSH_ASKPASS": script.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "XGHOSTTY_ASKPASS_FILE": file.path,
        ]
        return Prepared(environment: env, cleanup: {
            try? FileManager.default.removeItem(at: file)
        })
    }

    // MARK: 私有

    /// `~/.config/xghostty/.askpass`（0700）。
    private static func baseDir() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/xghostty/.askpass", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        return dir
    }

    /// 写好（幂等）askpass 脚本并返回路径。脚本读 `XGHOSTTY_ASKPASS_FILE`、打印密码后自删。
    private static func ensureScript() -> URL? {
        guard let dir = baseDir() else { return nil }
        let url = dir.appendingPathComponent("askpass.sh", isDirectory: false)
        // 脚本只回显临时文件内容并删除；不解析提示文本（host-key 由 accept-new 提前消化、不会进来）。
        let body = """
        #!/bin/sh
        f="$XGHOSTTY_ASKPASS_FILE"
        [ -n "$f" ] && [ -r "$f" ] || exit 1
        cat "$f"
        rm -f "$f"
        """
        // 内容固定，写一次即可；总是覆盖以便升级脚本逻辑（开销可忽略）。
        guard let data = body.data(using: .utf8),
              FileManager.default.createFile(
                atPath: url.path, contents: data,
                attributes: [.posixPermissions: 0o700]) else {
            // createFile 在已存在时会截断重写——若失败（极少）尝试改权限后返回。
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: url.path)
                return url
            }
            return nil
        }
        return url
    }
}
#endif
