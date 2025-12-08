import SwiftUI

@main
struct CircadianLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateIcon()

            // Handle both left and right clicks
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleClick(_:))
            button.target = self
        }

        // Observe state changes to update icon
        appState.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(appState)
        )
    }

    private func updateIcon() {
        if let button = statusItem.button {
            let symbolName = appState.isEnabled ? "sun.max.fill" : "sun.max"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CircadianLights")
            button.image?.isTemplate = true
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: toggle on/off
            appState.isEnabled.toggle()

            // Show brief visual feedback
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                button.image?.isTemplate = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.updateIcon()
                }
            }
        } else {
            // Left-click: show/hide popover
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)

            // Ensure popover is key window
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

import Combine
