import AppKit
import Foundation
import Testing
@testable import Ghostty

struct MenuShortcutManagerTests {
    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/779", id: 779))
    func unbindShouldDiscardDefault() async throws {
        let config = try TemporaryConfig("keybind = super+d=unbind")

        let item = NSMenuItem(title: "Split Right", action: #selector(BaseTerminalController.splitRight(_:)), keyEquivalent: "d")
        item.keyEquivalentModifierMask = .command
        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)

        try config.reload("")

        await manager.reset()
        await manager.syncMenuShortcut(config, action: "new_split:right", menuItem: item)

        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @MainActor @Test func physicalBackquoteUsesCurrentKeyboardLayout() throws {
        let config = try TemporaryConfig("keybind=super+backquote=toggle_quick_terminal")
        let expected = try #require(KeyboardLayout.character(for: 0x32, modifiers: .command))
        let item = NSMenuItem(title: "Quick Terminal", action: nil, keyEquivalent: "")
        let manager = Ghostty.MenuShortcutManager()

        manager.reset()
        manager.syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: item)

        #expect(item.keyEquivalent == String(expected))
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(!item.allowsAutomaticKeyEquivalentLocalization)
        #expect(!item.allowsAutomaticKeyEquivalentMirroring)
    }

    @Test(.bug("https://github.com/ghostty-org/ghostty/issues/11396", id: 11396))
    func overrideDefault() async throws {
        let config = try TemporaryConfig("keybind=super+h=goto_split:left")

        let hideItem = NSMenuItem(title: "Hide Ghostty", action: "hide:", keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = .command

        let goToLeftItem = NSMenuItem(title: "Select Split Left", action: "splitMoveFocusLeft:", keyEquivalent: "")

        let manager = await Ghostty.MenuShortcutManager()
        await manager.reset()

        await manager.syncMenuShortcut(config, action: nil, menuItem: hideItem)
        await manager.syncMenuShortcut(config, action: "goto_split:left", menuItem: goToLeftItem)

        #expect(hideItem.keyEquivalent.isEmpty)
        #expect(hideItem.keyEquivalentModifierMask.isEmpty)

        #expect(goToLeftItem.keyEquivalent == "h")
        #expect(goToLeftItem.keyEquivalentModifierMask == .command)
    }

    @Test
    @MainActor
    func editMenuFallbackOnlyAppliesWhenShortcutIsMissing() {
        let cleared = NSMenuItem(title: "Copy", action: "copy:", keyEquivalent: "")
        EditMenuFallbackShortcut.applyIfMissing(cleared, equivalent: "c", modifiers: [.command])
        #expect(cleared.keyEquivalent == "c")
        #expect(cleared.keyEquivalentModifierMask == .command)

        let alreadySet = NSMenuItem(title: "Copy", action: "copy:", keyEquivalent: "x")
        alreadySet.keyEquivalentModifierMask = [.command, .shift]
        EditMenuFallbackShortcut.applyIfMissing(alreadySet, equivalent: "c", modifiers: [.command])
        #expect(alreadySet.keyEquivalent == "x")
        #expect(alreadySet.keyEquivalentModifierMask == [.command, .shift])

        // A nil menu item should be a safe no-op.
        EditMenuFallbackShortcut.applyIfMissing(nil, equivalent: "c", modifiers: [.command])
    }
}
