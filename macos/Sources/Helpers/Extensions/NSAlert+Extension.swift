import AppKit

extension NSAlert {
    static func reviewWindowsAlert(
        messageText: String,
        informativeText: String = LocalizedString.text("If you don't review your windows, any running processes will be terminated"),
        terminateNowButtonTitle: String = LocalizedString.text("Terminate Processes")
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: LocalizedString.text("Review Windows..."))
        alert.addButton(withTitle: terminateNowButtonTitle)
        alert.addButton(withTitle: LocalizedString.text("Cancel"))
        alert.alertStyle = .warning

        return alert
    }
}
