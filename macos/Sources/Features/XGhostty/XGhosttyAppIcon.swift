#if XGHOSTTY
import AppKit

/// 给 XGhostty 的应用图标叠加一个「X」角标，使其在 Dock / Finder / 启动台里与原版 Ghostty 区分。
///
/// XGhostty 复用主 app 的 AppIcon 资源（`ASSETCATALOG_COMPILER_APPICON_NAME = Ghostty`），
/// 所以底图与 Ghostty 完全相同。这里在底图右下角合成一个红底白「X」圆形角标，由
/// [[AppIconUpdater]].update 在设置 bundle 图标时调用（`NSWorkspace.setIcon(forFile:)` 写入的是
/// bundle 自定义图标，Dock 与 Finder 都认）。底图取自显式图标（用户在 config 选了某款）或
/// app 默认图标；写入的是 Finder 自定义图标属性、不动 Assets.car，故不会每次启动累加角标。
enum XGhosttyAppIcon {
    /// 在底图右下角叠加红底白「X」角标返回新图。`base` 为 nil（official/默认）时用 app 当前图标作底。
    @MainActor
    static func withXBadge(base: NSImage?) -> NSImage? {
        guard let source = base ?? NSImage(named: NSImage.applicationIconName) else { return base }

        let side: CGFloat = 1024
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))

        // 右下角圆形角标：红底 + 细白描边，与深色底图分离。
        let diameter = side * 0.46
        let margin = side * 0.02
        let badgeRect = NSRect(
            x: side - diameter - margin, y: margin, width: diameter, height: diameter)
        let circle = NSBezierPath(ovalIn: badgeRect)
        NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.18, alpha: 1).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.92).setStroke()
        circle.lineWidth = side * 0.013
        circle.stroke()

        // 居中白色「X」。
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: diameter * 0.66, weight: .heavy),
            .paragraphStyle: para,
        ]
        let glyph = "X" as NSString
        let glyphSize = glyph.size(withAttributes: attrs)
        glyph.draw(
            at: NSPoint(
                x: badgeRect.midX - glyphSize.width / 2,
                y: badgeRect.midY - glyphSize.height / 2),
            withAttributes: attrs)

        return canvas
    }
}
#endif
