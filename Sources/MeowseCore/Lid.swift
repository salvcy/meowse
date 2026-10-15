import Foundation

/// Keeping the Mac awake with the lid closed. Only root can stop lid-close
/// sleep, so Meowse ships a small helper, a launchd daemon an administrator
/// approves once in System Settings. Meowse holds it over XPC while Keep
/// Awake is on with this option set; the helper lets go when Meowse does, or
/// if the connection drops because Meowse quit or crashed.
@objc public protocol LidService {
    /// Turns lid-close sleep off (true) or back on (false). The reply says
    /// whether it worked.
    func hold(_ on: Bool, reply: @escaping (Bool) -> Void)
}

public enum Lid {

    /// The helper's launchd label and XPC service: named for the app, so a
    /// copy with its own bundle identifier has its own helper.
    public static func service(forApp bundleID: String) -> String { bundleID + ".lid" }

    /// On battery at or under this charge, the lid is let go, so a closed Mac
    /// in a bag doesn't run flat.
    public static let lowBattery = 20

    public static func shouldHold(keepAwake: Bool, enabled: Bool, onBattery: Bool, charge: Int) -> Bool {
        keepAwake && enabled && !(onBattery && charge <= lowBattery)
    }
}
