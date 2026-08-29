import AppKit
import AuthReachCore
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let model = AppModel()
    private var mainWindow: NSWindow?
    private var hudPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        statusItem.button?.image = NSImage(systemSymbolName: "key.fill",
                                           accessibilityDescription: "AuthReach")
        let menu = NSMenu()
        menu.delegate = self // rebuilt fresh on every open — countdowns stay live
        statusItem.menu = menu

        KeyboardShortcuts.onKeyUp(for: .toggleHud) { [weak self] in
            self?.toggleHud()
        }

        model.onRecentChanged = { /* menu rebuilds on open via delegate */ }
    }

    // MARK: - Tray menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.recent.isEmpty {
            let empty = NSMenuItem(title: "No codes yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in model.recent.prefix(8) {
                var title = "\(entry.code) — \(entry.service) (\(relativeTime(entry.receivedAt)))"
                if let expiry = expiryLabel(entry.expiresAt) {
                    title += "  ·  \(expiry.label.lowercased())"
                }
                let item = NSMenuItem(title: title, action: #selector(copyCode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.code
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem({ let i = NSMenuItem(title: "Open AuthReach…", action: #selector(openMain), keyEquivalent: ""); i.target = self; return i }())
        menu.addItem({ let i = NSMenuItem(title: "Check now", action: #selector(checkNow), keyEquivalent: ""); i.target = self; return i }())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AuthReach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func copyCode(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { model.copy(code) }
    }

    @objc private func checkNow() {
        Task { await model.pollNow() }
    }

    // MARK: - HUD

    private func toggleHud() {
        if let hudPanel, hudPanel.isVisible {
            hudPanel.orderOut(nil)
            return
        }
        showHud()
    }

    private func showHud() {
        if hudPanel == nil {
            let panel = NSPanel(contentRect: .zero,
                                styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: HudView(model: model) { [weak self] in
                self?.hudPanel?.orderOut(nil)
            })
            hudPanel = panel
        }
        guard let panel = hudPanel else { return }
        // Anchor near the status item (its screen), top-center under the menu bar.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.layoutIfNeeded()
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.maxY - size.height - 8))
        }
        panel.orderFrontRegardless()
    }

    // MARK: - Main window

    @objc func openMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: .zero,
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "AuthReach"
            window.contentViewController = NSHostingController(rootView: MainView(model: model))
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 620))
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem({ let i = NSMenuItem(title: "Open AuthReach…", action: #selector(openMain), keyEquivalent: "o"); i.target = self; return i }())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AuthReach", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }
}
