import Foundation
import Security
import MeowseCore

// Meowse's lid helper. launchd runs it as root: once at load, to undo a hold
// left by a crash, and again whenever Meowse connects. It stops lid-close
// sleep with `pmset disablesleep` only while Meowse holds the connection, and
// turns sleep back on when Meowse lets go, quits or crashes.

/// Kept while sleep is off, so a hold this helper didn't see end (it was
/// killed, or the Mac lost power) is undone the next time it starts.
let marker = URL(fileURLWithPath: "/Library/Application Support/Meowse/lid-held")

func setSleepDisabled(_ on: Bool) -> Bool {
    let pmset = Process()
    pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    pmset.arguments = ["-a", "disablesleep", on ? "1" : "0"]
    do {
        try pmset.run()
        pmset.waitUntilExit()
    } catch {
        return false
    }
    guard pmset.terminationStatus == 0 else { return false }
    if on {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    } else {
        try? FileManager.default.removeItem(at: marker)
    }
    return true
}

/// Only the app this helper ships in, signed by the same team, may connect.
func clientRequirement() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
          let app = Bundle.main.bundleIdentifier else { return nil }
    return "identifier \"\(app)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
}

/// One hold at a time, by whichever connection asked last.
final class Helper: NSObject, NSXPCListenerDelegate {

    private let queue = DispatchQueue(label: "lid")
    private var holder: NSXPCConnection?
    private var connections = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LidService.self)
        connection.exportedObject = Session(helper: self, connection: connection)
        connection.invalidationHandler = { [weak self, weak connection] in self?.ended(connection) }
        connection.interruptionHandler = { [weak self, weak connection] in self?.ended(connection) }
        queue.sync { connections += 1 }
        connection.resume()
        return true
    }

    func hold(_ on: Bool, for connection: NSXPCConnection) -> Bool {
        queue.sync {
            let done = setSleepDisabled(on)
            holder = on && done ? connection : nil
            return done
        }
    }

    private func ended(_ connection: NSXPCConnection?) {
        queue.sync {
            if let holder, holder === connection {
                _ = setSleepDisabled(false)
                self.holder = nil
            }
            connections = max(0, connections - 1)
            exitIfIdle()
        }
    }

    /// launchd starts it again when Meowse next connects.
    func exitIfIdle() {
        guard connections == 0, holder == nil else { return }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.connections == 0, self.holder == nil else { return }
            exit(0)
        }
    }
}

final class Session: NSObject, LidService {
    private let helper: Helper
    private weak var connection: NSXPCConnection?

    init(helper: Helper, connection: NSXPCConnection) {
        self.helper = helper
        self.connection = connection
    }

    func hold(_ on: Bool, reply: @escaping (Bool) -> Void) {
        guard let connection else { return reply(false) }
        reply(helper.hold(on, for: connection))
    }
}

if FileManager.default.fileExists(atPath: marker.path) {
    _ = setSleepDisabled(false)
}
guard let requirement = clientRequirement(), let app = Bundle.main.bundleIdentifier else {
    exit(0)  // unsigned or not inside the app: nothing may use it
}
let helper = Helper()
let listener = NSXPCListener(machServiceName: Lid.service(forApp: app))
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = helper
listener.resume()
helper.exitIfIdle()
dispatchMain()
