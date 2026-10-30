import AppKit

/// Offers to move a downloaded copy into Applications. Opened where it was
/// downloaded, macOS runs the app from a read-only random path (App
/// Translocation), where it can't update itself.
enum AppMover {

    private static let declinedKey = "moveToApplications.declined"

    /// True if the app is moving and relaunching, so launch should stop here.
    static func offerMove() -> Bool {
        let app = Bundle.main.bundleURL
        guard !isInApplications(app), wasDownloaded(app),
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }
        let source = originalURL(of: app) ?? app
        let folder = FileManager.default.displayName(atPath: source.deletingLastPathComponent().path)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Move Meowse to Applications?")
        alert.informativeText = String(localized: "Meowse is running from \(folder), where it can’t update itself.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: declinedKey)
            }
            return false
        }

        do {
            NSApp.relaunch(try move(source))
            return true
        } catch {
            let failed = NSAlert()
            failed.messageText = String(localized: "Meowse couldn’t move itself to Applications.")
            failed.informativeText = String(localized: "\(error.localizedDescription) You can drag Meowse there in Finder.", comment: "After the system's error message")
            failed.runModal()
            return false
        }
    }

    /// Copies the app into Applications (or ~/Applications without admin
    /// rights), replacing an older copy, and moves the original to the Trash.
    private static func move(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let folder = fm.isWritableFile(atPath: "/Applications")
            ? URL(fileURLWithPath: "/Applications", isDirectory: true)
            : try fm.url(for: .applicationDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        removeQuarantine(destination)
        try? fm.trashItem(at: source, resultingItemURL: nil)  // fails harmlessly on a read-only disk image
        return destination
    }

    private static func isInApplications(_ app: URL) -> Bool {
        let path = app.resolvingSymlinksInPath().path
        return FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    /// Local builds carry no quarantine flag, so they're never offered a move.
    private static func wasDownloaded(_ app: URL) -> Bool {
        app.path.contains("/AppTranslocation/")
            || getxattr(app.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Where a translocated app really is. Security.framework exports this but
    /// doesn't declare it in the SDK.
    private static func originalURL(of app: URL) -> URL? {
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard app.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(app as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// The app already passed Gatekeeper to get here. Left quarantined, the
    /// copy would be translocated again.
    private static func removeQuarantine(_ app: URL) {
        removexattr(app.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}

extension NSApplication {
    /// Opens `app` once this process has exited (the single-instance guard
    /// would refuse it earlier), then quits. Stays running if that can't be set up.
    func relaunch(_ app: URL) {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; "
                                    + "/usr/bin/open \"$0\" || { /bin/sleep 2; /usr/bin/open \"$0\"; }",
                                app.path]
        do {
            try relauncher.run()
        } catch {
            NSLog("Meowse: couldn't relaunch: \(error)")
            return
        }
        terminate(nil)
    }
}
