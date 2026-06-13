#if XGHOSTTY
import Foundation

enum SessionCommandError: Error, CustomStringConvertible {
    case invalidHost(String)
    case invalidPort(Int)
    case invalidUser(String)
    case invalidProxy(String)

    var description: String {
        switch self {
        case .invalidHost(let s): return "非法主机名: \(s)"
        case .invalidPort(let p): return "非法端口: \(p)"
        case .invalidUser(let s): return "非法用户名: \(s)"
        case .invalidProxy(let s): return "非法跳板: \(s)"
        }
    }
}

/// 从 SessionNode 叶子构造 ssh 命令 + 注入 env。纯函数，可单测。
///
/// 安全要点：`command` 最终经 `/bin/sh -c` 执行（macOS 上 `login … bash -c "exec -l <cmd>"`），
/// 所以 host/user/port/proxy 全部**白名单校验**后才允许拼接，杜绝 shell 注入。
enum SessionCommandBuilder {
    /// 构造结果。`command == nil` 表示本地 shell（不走 ssh）。
    struct Built: Equatable {
        var command: String?
        var environment: [String: String]
    }

    /// 所有会话默认注入：远端 terminfo + UTF-8 locale。
    static let baseEnv: [String: String] = [
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
    ]

    /// 密码登录策略（控制 ssh 认证方式协商）。
    enum PasswordPolicy {
        case none      // 无密码（密钥登录 / 无凭据）：不加密码相关选项，走 ssh 默认
        case auto      // 先试默认公钥、失败再 keyboard-interactive/password（混合机群默认）
        case strict    // 仅密码：关 pubkey，只走 keyboard-interactive/password
    }

    /// 构造 ssh 命令。
    /// - policy: 密码登录策略。`.auto` 先公钥后密码（同一密码身份兼容只收密钥/只收密码的混合机群）；
    ///   `.strict` 仅密码（关 pubkey）；`.none` 不加密码选项（密钥登录或无凭据）。
    ///   askpass 的环境变量由控制器另行注入（见 XGhosttyAskpass），此处只调命令行选项。
    static func build(for node: SessionNode, policy: PasswordPolicy = .none,
                      jump: Jump? = nil) throws -> Built {
        // 本地 shell：不设 command，交给默认 shell。
        if node.isLocalShell {
            return Built(command: nil, environment: baseEnv)
        }

        guard let host = node.host, validHost(host) else {
            throw SessionCommandError.invalidHost(node.host ?? "")
        }

        var parts: [String] = [
            "ssh", "-t",                         // 强制分配 tty（带远端命令时仍保持交互）
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            // host-key 安全：自动接受**新**主机指纹（免首连 yes/no 卡住自动登录），
            // 但**变更**的指纹仍拒绝（防中间人）。密码自动登录尤其依赖它，否则 yes/no
            // 提示会被 askpass 当成密码答进去。对密钥/手动登录也是更顺手的默认。
            "-o", "StrictHostKeyChecking=accept-new",
            // 兼容老服务器（CentOS6/7、旧 dropbear 等只支持 RSA-SHA1 的 ssh-rsa）：用 append（`+`）
            // 把 ssh-rsa 加回允许列表——现代服务器仍协商更强算法，仅当对端只有 ssh-rsa 时才回落，
            // 不降级现代连接。WindTerm/Xshell 走 libssh2 默认就支持，OpenSSH 9+ 默认禁用故需显式开。
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
            "-o", "HostKeyAlgorithms=+ssh-rsa",
        ]

        // 密码登录方式协商：
        //  - .auto：先试默认公钥（~/.ssh/id_rsa 等，无 passphrase 即静默尝试），失败再 keyboard-
        //    interactive/password（askpass 送密码，错一次即止）。同一密码身份下「只收密钥」与「只收
        //    密码」的混合机群都能登——复刻 WindTerm 的 www。
        //  - .strict：仅密码，关 pubkey（与"只收密钥"的服务端零交集会被直接拒，按需选）。
        switch policy {
        case .none:
            break
        case .auto:
            parts += [
                "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        case .strict:
            parts += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        }

        if let port = node.port {
            guard (1...65535).contains(port) else {
                throw SessionCommandError.invalidPort(port)
            }
            parts += ["-p", String(port)]
        }

        // SSH 私钥登录（`-i`）：路径单引号包裹防注入/空格（与 OSC7 bootstrap 同法），
        // `~` 先本地展开（单引号会阻断 shell 展开）；`IdentitiesOnly=yes` 强制只用此钥匙，
        // 避免 agent 里挂了多把钥匙触发 "Too many authentication failures"。
        if let identity = node.identityFile, !identity.isEmpty {
            let expanded = (identity as NSString).expandingTildeInPath
            parts += ["-i", singleQuote(expanded), "-o", "IdentitiesOnly=yes"]
        }

        // 跳板：引用式（jump 参数）优先——有 auth 走 ProxyCommand 携带跳板自己的密钥/密码，
        // 无 auth 退化成 `-J`（默认密钥）；否则用手动填的 proxyJump 字符串走 `-J`。
        if let jump {
            if jump.hasAuth {
                parts += ["-o", singleQuote("ProxyCommand=" + proxyCommand(for: jump))]
            } else {
                var ep = jump.endpoint
                if let p = jump.port { ep += ":\(p)" }
                parts += ["-J", ep]
            }
        } else if let manual = node.proxyJump, !manual.isEmpty {
            guard validProxy(manual) else {
                throw SessionCommandError.invalidProxy(manual)
            }
            parts += ["-J", manual]
        }

        var target = host
        if let user = node.user, !user.isEmpty {
            guard validName(user) else {
                throw SessionCommandError.invalidUser(user)
            }
            target = "\(user)@\(host)"
        }
        parts.append(target)

        // 远端目录跟踪（OSC 7）：连上后让远端 shell 每次提示符上报当前目录，
        // 这样 ⌘T 复制能 cd 到远端目录、窗口标题能显示远端路径。
        // 用 `ssh -t host '<cmd>'` 位置参数形式（兼容老 OpenSSH，不用 RemoteCommand）：
        // 设好 PROMPT_COMMAND 后 exec 登录 shell。失败（zsh / .bashrc 覆盖 / 非 bash）
        // 只会让上报不生效，连接照常 —— 自动降级到“不 cd”。
        parts.append(remoteOSC7Bootstrap())

        return Built(command: parts.joined(separator: " "), environment: baseEnv)
    }

    /// 把一条跳板机构造成端点 `[user@]host`（端口另走；白名单校验，非法返回 nil）。
    static func jumpEndpoint(for jh: JumpHost) -> String? {
        guard validHost(jh.host) else { return nil }
        var s = ""
        if let u = jh.user, !u.isEmpty, validName(u) { s += "\(u)@" }
        s += jh.host
        return s
    }

    /// 引用式跳板的解析结果（控制器算好传入 build）。无 auth → 退化成 `-J`；有 auth → `ProxyCommand`。
    struct Jump {
        var endpoint: String                  // [user@]host
        var port: Int?
        var identityFile: String?             // 跳板密钥路径（key 凭据）
        var askpassEnv: [String: String]?     // 跳板密码凭据 → 它自己的 askpass 环境（注入 ProxyCommand）
        var hasAuth: Bool { identityFile != nil || askpassEnv != nil }
    }

    /// 友好的连接信息（终端首行展示用）：只含 user@host/-p/-J，
    /// 不含内部的 ServerAlive/`-t`/OSC7 bootstrap 等噪音。本地 shell 返回 nil。
    /// - viaJump: 引用式跳板的端点（用于首行展示，让用户看到流量在绕跳板）。
    static func displayCommand(for node: SessionNode, viaJump: String? = nil) -> String? {
        guard !node.isLocalShell, let host = node.host else { return nil }
        var s = "ssh "
        if let user = node.user, !user.isEmpty { s += "\(user)@" }
        s += host
        if let port = node.port { s += " -p \(port)" }
        if let identity = node.identityFile, !identity.isEmpty {
            s += " -i \((identity as NSString).abbreviatingWithTildeInPath)"
        }
        if let viaJump, !viaJump.isEmpty { s += " -J \(viaJump)" }
        else if let jump = node.proxyJump, !jump.isEmpty { s += " -J \(jump)" }
        return s
    }

    /// 远端 bootstrap 命令（已做单引号包裹，可直接作为 ssh 的位置参数 token）。
    private static func remoteOSC7Bootstrap() -> String {
        // OSC 7：ESC ] 7 ; file://HOST/PWD ESC \ —— printf 里 \033=ESC、\\=反斜杠(ST)。
        // host 必须写字面 `localhost`：Ghostty 故意只接受本机 hostname 的 OSC 7（防 ssh 伪造），
        // 远端真实 hostname 会被丢弃，而 isLocal("localhost") 恒为真。pwd 仅用于远端 cd，安全。
        let osc7 = #"printf "\033]7;file://localhost%s\033\\" "$PWD""#
        // 登录瞬间先 emit 一次（任何 shell 都生效）→ 远端首次 pwd 精确卡在「登录成功」点，
        // 既让座舱「已连接」绿图标准确，又顺带为 zsh 等无 PROMPT_COMMAND 的远端兜底首个 pwd；
        // 之后交给 PROMPT_COMMAND 每个提示符更新（bash）。
        let script = "\(osc7); export PROMPT_COMMAND='\(osc7)'; exec \"${SHELL:-/bin/bash}\" -l"
        // 整段用单引号包裹，内部单引号转义为 '\'' —— 阻止本地 shell 展开 $/$()。
        return "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 构造跳板的 `ProxyCommand` 值（不含外层引号；调用方 singleQuote 包裹）。
    /// = `[env <askpass…>] ssh <兼容选项> [-p port] [-i key -o IdentitiesOnly=yes / 关密码] -W %h:%p endpoint`。
    /// askpass 环境值（路径，无空格）直接 `env K=V` 注入,让内层 ssh 用**跳板自己的**密码；
    /// 密钥则 `-i` 并禁密码回落,避免误用目标机的 askpass 密码。
    private static func proxyCommand(for jump: Jump) -> String {
        var s = ""
        if let env = jump.askpassEnv {
            s += "env "
            for (k, v) in env.sorted(by: { $0.key < $1.key }) { s += "\(k)=\(v) " }
        }
        s += "ssh -o StrictHostKeyChecking=accept-new"
        s += " -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa"
        if let p = jump.port { s += " -p \(p)" }
        if let id = jump.identityFile, !id.isEmpty {
            let expanded = (id as NSString).expandingTildeInPath
            // 密钥登录跳板：只用此钥匙 + 禁密码,失败也不回落到目标机的 askpass 密码。
            s += " -i \(singleQuote(expanded)) -o IdentitiesOnly=yes"
            s += " -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no"
        } else if jump.askpassEnv != nil {
            s += " -o NumberOfPasswordPrompts=1"
        }
        s += " -W %h:%p \(jump.endpoint)"
        return s
    }

    /// 单引号包裹路径，防 shell 注入/空格（内部单引号转义为 '\'' ，与 remoteOSC7Bootstrap 同法）。
    private static func singleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: 白名单校验

    /// 主机名 / 用户名：字母数字 . _ -
    private static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// 主机：普通主机名/IPv4 走 validName；含冒号按 IPv6（仅 hex/冒号/点）。
    private static func validHost(_ s: String) -> Bool {
        if s.contains(":") {
            return s.range(of: "^[0-9A-Fa-f:.]+$", options: .regularExpression) != nil
        }
        return validName(s)
    }

    /// 跳板：user@host 或 host。
    private static func validProxy(_ s: String) -> Bool {
        let comps = s.split(separator: "@", maxSplits: 1).map(String.init)
        if comps.count == 2 { return validName(comps[0]) && validHost(comps[1]) }
        return validHost(s)
    }
}
#endif
