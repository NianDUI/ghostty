import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) var openURL

    #if XGHOSTTY
    private let githubURL = URL(string: "https://github.com/NianDUI/ghostty")
    #else
    private let githubURL = URL(string: "https://github.com/ghostty-org/ghostty")
    #endif
    private let docsURL = URL(string: "https://ghostty.org/docs")

    /// Use the linked library's version, including for local Xcode builds whose
    /// bundle metadata still contains the project defaults (0.1 / 1).
    private let version = Ghostty.info.version

    private var commit: String? {
        if let metadata = version.split(separator: "+", maxSplits: 1).dropFirst().first,
           metadata.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil,
           metadata.contains(where: { $0 != "0" }) {
            return String(metadata)
        }

        // Release builds may supply the commit separately from the core version.
        guard let commit = Bundle.main.infoDictionary?["GhosttyCommit"] as? String,
              !commit.isEmpty else { return nil }
        return commit
    }

    private var appVersion: String? {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty, version != "0.1" else { return nil }
        return version
    }

    private var releaseBuild: String? {
        guard appVersion != nil else { return nil }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private enum VersionConfig {
        case stable(version: String)
        case tip(commit: String?)
        case other(String)
        case none

        init(version: String?) {
            guard let version else { self = .none; return }
            if version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                self = .stable(version: version)
                return
            }
            if version.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil {
                self = .tip(commit: version)
                return
            }
            self = .other(version)
        }

        var url: URL? {
            switch self {
            case .stable(let version):
                let slug = version.replacingOccurrences(of: ".", with: "-")
                return URL(string: "https://ghostty.org/docs/install/release-notes/\(slug)")
            default:
                return nil
            }
        }
    }

    private var versionConfig: VersionConfig { VersionConfig(version: version) }

    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    // This creates a background style similar to the Apple "About My Mac" Window
    private struct VisualEffectBackground: NSViewRepresentable {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode
        let isEmphasized: Bool

        init(material: NSVisualEffectView.Material,
             blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
             isEmphasized: Bool = false) {
            self.material = material
            self.blendingMode = blendingMode
            self.isEmphasized = isEmphasized
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
            nsView.material = material
            nsView.blendingMode = blendingMode
            nsView.isEmphasized = isEmphasized
        }

        func makeNSView(context: Context) -> NSVisualEffectView {
            let visualEffect = NSVisualEffectView()
            visualEffect.autoresizingMask = [.width, .height]
            return visualEffect
        }
    }

    var body: some View {
        VStack(alignment: .center) {
            CyclingIconView()

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("Ghostty")
                        .bold()
                        .font(.title)
                    Text("Fast, native, feature-rich terminal \nemulator pushing modern features.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    switch versionConfig {
                    case .stable(let version):
                        PropertyRow(label: "Version", text: version, url: versionConfig.url)
                    case .tip:
                        PropertyRow(label: "Version", text: "Tip Release")
                    case .other(let v):
                        PropertyRow(label: "Version", text: v)
                    case .none:
                        EmptyView()
                    }
                    if let commit {
                        PropertyRow(label: "Build", text: commit,
                                    url: githubURL?.appendingPathComponent("/commit/\(commit)"))
                    }
                    #if XGHOSTTY
                    if let appVersion {
                        PropertyRow(label: "App Version", text: appVersion)
                    }
                    #endif
                    if let releaseBuild {
                        PropertyRow(label: "Release Build", text: releaseBuild)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button("Docs") {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button("GitHub") {
                            openURL(url)
                        }
                    }
                }

                if let copy = self.copyright {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 256)
        .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }

    private struct PropertyRow: View {
        private let label: String
        private let text: String
        private let url: URL?

        init(label: String, text: String, url: URL? = nil) {
            self.label = label
            self.text = text
            self.url = url
        }

        @ViewBuilder private var textView: some View {
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }

        var body: some View {
            HStack(spacing: 4) {
                Text(label)
                    .frame(width: 126, alignment: .trailing)
                    .padding(.trailing, 2)
                if let url {
                    Link(destination: url) {
                        textView
                    }
                } else {
                    textView
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
    }
}
