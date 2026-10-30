import AppKit
import SwiftUI
import MeowseCore

/// Settings window with toolbar tabs. The process exits when it closes.
///
/// The window is always as tall as the selected tab's content, and only
/// `TabsController` changes its size: each tab reports its height, and the
/// window follows with AppKit's animated resize, which draws every step. The
/// content is pinned to the top, so nothing above a change moves. (Left to
/// NSTabViewController and SwiftUI, the size changed partway through drawing
/// a frame, and the screen showed a mismatched layout until the next one.)
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?
    private let tabs = TabsController()

    init(store: SettingsStore, awake: AwakeController, updater: Updater, requestPermission: @escaping () -> Void) {
        let tabs = self.tabs
        tabs.tabStyle = .toolbar

        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(view
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak tabs, weak host] _ in
                    // Reported while a frame is drawn; the window follows after it.
                    DispatchQueue.main.async {
                        if let tabs, let host { tabs.contentChanged(in: host) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top))
            // No preferredContentSize: AppKit would size the window from it too.
            host.sizingOptions = []
            // The toolbar sits above the content, not over it; measured with the
            // title bar's safe area, a tab came out 28 pt taller than it lays out.
            host.safeAreaRegions = []
            host.title = title  // becomes the window title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add(String(localized: "General", comment: "Settings tab"), "gearshape", GeneralTab(store: store, requestPermission: requestPermission))
        add(String(localized: "Mouse", comment: "Settings tab"), "computermouse", MouseTab(store: store))
        add(String(localized: "Scrolling", comment: "Settings tab, and a menu section header with a switch"), "scroll", ScrollingTab(store: store))
        add(String(localized: "Hotkeys", comment: "Settings tab"), "keyboard", HotkeysTab(store: store))
        add(String(localized: "Awake", comment: "Settings tab for Keep Awake and Wiggle Cursor"), "cup.and.saucer", AwakeTab(store: store, awake: awake))
        add(String(localized: "Updates", comment: "Settings tab"), "arrow.down.circle", UpdatesTab(store: store, updater: updater))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        tabs.fitWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: SettingsTab) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        // Before the window first shows, the tab view doesn't report the switch yet.
        tabs.fitWindow()
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

/// Toolbar tabs whose window is as tall as the selected tab's content,
/// anchored at the top.
private final class TabsController: NSTabViewController {

    /// A tab's content changed height (a list opened, a row appeared).
    func contentChanged(in host: NSViewController) {
        if host === tabViewItems[selectedTabViewItemIndex].viewController { fitWindow() }
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow()
    }

    /// Measured, not taken from the change report: the first layout after
    /// the window appears reports the content 28 pt taller than it settles.
    func fitWindow() {
        guard let window = view.window,
              let host = tabViewItems[selectedTabViewItemIndex].viewController as? NSHostingController<AnyView> else { return }
        // With no height on offer, the content pinned to the top reports its own.
        let height = host.sizeThatFits(in: NSSize(width: 480, height: 0)).height
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 480, height: height))
        guard abs(target.height - window.frame.height) > 0.5 || abs(target.width - window.frame.width) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
