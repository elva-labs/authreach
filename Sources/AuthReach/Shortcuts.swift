import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global shortcut toggling the code HUD (default matches the original:
    /// ⌘⇧O). Recorded in the main window's preferences.
    static let toggleHud = Self("toggleHud", default: .init(.o, modifiers: [.command, .shift]))
}
