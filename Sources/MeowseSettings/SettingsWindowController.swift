import AppKit
import SwiftUI
import MeowseCore

/// Settings window with toolbar tabs. The process exits when it closes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?
    private let tabs = FittingTabViewController()

    init(store: SettingsStore, awake: AwakeController, updater: Updater, requestPermission: @escaping () -> Void) {
        let tabs = self.tabs
        tabs.tabStyle = .toolbar

        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: AnyView(EmptyView()))
            // The window follows the tab's size through preferredContentSize.
            // SwiftUI would update it midway through drawing a frame, and the
            // window resized then kept showing the old layout until something
            // next woke the app: seconds of blank space after a list opened.
            // Set it just after the frame instead.
            host.rootView = AnyView(view.onGeometryChange(for: CGSize.self) { $0.size } action: { [weak host] size in
                DispatchQueue.main.async { host?.preferredContentSize = size }
            })
            host.sizingOptions = []
            host.preferredContentSize = host.sizeThatFits(in: NSSize(width: 480, height: 10_000))
            host.title = title  // becomes the window title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", GeneralTab(store: store, requestPermission: requestPermission))
        add("Mouse", "computermouse", MouseTab(store: store))
        add("Scrolling", "scroll", ScrollingTab(store: store))
        add("Hotkeys", "keyboard", HotkeysTab(store: store))
        add("Awake", "cup.and.saucer", AwakeTab(store: store, awake: awake))
        add("Updates", "arrow.down.circle", UpdatesTab(store: store, updater: updater))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
    }

    func show() {
        if window?.isVisible == false { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Resizes the window to the selected tab's SwiftUI content, anchored at
/// the top. Within a tab, the window follows the content through its
/// preferredContentSize (see `SettingsWindowController.init`).
private final class FittingTabViewController: NSTabViewController {

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow()
    }

    /// A tab that was hidden may have changed size since it was last shown.
    override func tabView(_ tabView: NSTabView, willSelect item: NSTabViewItem?) {
        if let host = item?.viewController as? NSHostingController<AnyView> {
            host.preferredContentSize = host.sizeThatFits(in: NSSize(width: 480, height: 10_000))
        }
        super.tabView(tabView, willSelect: item)
    }

    private func fitWindow() {
        guard let window = view.window,
              let size = tabViewItems[selectedTabViewItemIndex].viewController?.preferredContentSize,
              size.width > 0, size.height > 0 else { return }
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
