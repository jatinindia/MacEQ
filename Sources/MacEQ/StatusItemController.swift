import SwiftUI

/// The menu-bar icon and its popover, in AppKit rather than a SwiftUI
/// MenuBarExtra: MenuBarExtra's panel grows with its content but never shrinks
/// back, so after Parametric → Graphic (or closing Diagnostics) the controls
/// floated in a band of empty glass. NSPopover follows the hosting
/// controller's preferred size in both directions.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let controller: EQController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(controller: EQController) {
        self.controller = controller
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        guard let button = statusItem.button else {
            fatalError("NSStatusItem was created without a button")
        }
        button.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "MacEQ")
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    @objc private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A fresh view per opening, released on close: the popover's own
        // onAppear/onDisappear (and the spectrum's) are what start and stop
        // the display timers, and a view that outlives the popover never
        // disappears.
        let hostingController = NSHostingController(rootView: EQPopoverView(controller: controller))
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        // A menu-bar click doesn't activate the app, and without that the
        // popover never becomes key, so its text fields can't be typed into.
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        popover.contentViewController = nil
    }
}
