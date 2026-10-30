import AppKit
import Combine
import CryptoKit
import MeowseCore
import Security

/// In-app updates from GitHub Releases.
///
/// Automatic checks are scheduled by macOS (`NSBackgroundActivityScheduler`)
/// at most once a day, so the app itself never polls. An update is installed
/// only after its checksum matches and its code signature satisfies the same
/// team and bundle identifier as the running app. The swap is an atomic
/// rename on the same volume, followed by a relaunch.
final class Updater: ObservableObject {

    static let shared = Updater()

    typealias State = UpdateStatus

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    let currentVersion: Version
    private let repository: String?
    private var release: Release?
    private var scheduler: NSBackgroundActivityScheduler?
    private var session: URLSession?
    private var checkInFlight = false
    /// Someone asked to see the result of the check in flight.
    private var userWaiting = false

    private static let lastCheckedKey = "updates.lastChecked"
    private static let day: TimeInterval = 24 * 3600

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        currentVersion = Version(info["CFBundleShortVersionString"] as? String ?? "") ?? Version("0")!
        repository = (info["MeowseUpdateRepository"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// The update found by the last successful check. It stays offered when a
    /// later check or the install fails.
    var availableVersion: String? { release?.version?.description }
    var availableNotes: String { release?.notes ?? "" }

    var releasePage: URL? { release.map(\.page).flatMap { $0.scheme == "https" ? $0 : nil } }

    // MARK: - Scheduling

    func setAutomaticChecks(_ enabled: Bool) {
        scheduler?.invalidate()
        scheduler = nil
        guard enabled, repository != nil else { return }

        let s = NSBackgroundActivityScheduler(identifier: "app.meowse.Meowse.update-check")
        s.repeats = true
        s.interval = Self.day
        s.tolerance = Self.day / 4
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            DispatchQueue.main.async { self?.check(userInitiated: false) }
            completion(.finished)
        }
        scheduler = s

        // The scheduler starts its interval fresh on every launch; catch up if the last check is stale.
        if isStale {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                // Only if automatic checks are still on and nothing has checked since.
                guard let self, self.scheduler != nil, self.isStale else { return }
                self.check(userInitiated: false)
            }
        }
    }

    private var isStale: Bool {
        lastChecked.map { Date().timeIntervalSince($0) > Self.day } ?? true
    }

    // MARK: - Checking

    func check(userInitiated: Bool) {
        if state == .installing { return }
        guard let repository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            if userInitiated { state = .failed(String(localized: "No update source is configured for this build.")) }
            return
        }
        if userInitiated {
            userWaiting = true
            state = .checking
        }
        // One request at a time; its result answers everyone waiting.
        guard !checkInFlight else { return }
        checkInFlight = true

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Meowse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        openSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.closeSession() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Release, UpdateError>
            if error != nil {
                result = .failure(.offline)
            } else if status == 404 {
                result = .failure(.noReleases)
            } else if status == 403 || status == 429 {
                result = .failure(.rateLimited)
            } else if status != 200 {
                result = .failure(.server(status))
            } else if let data, let release = try? JSONDecoder().decode(Release.self, from: data) {
                result = .success(release)
            } else {
                result = .failure(.malformed)
            }
            let userWaited = self.userWaiting
            self.checkInFlight = false
            self.userWaiting = false
            self.finishCheck(result, userInitiated: userWaited)
        }.resume()
    }

    private func finishCheck(_ result: Result<Release, UpdateError>, userInitiated: Bool) {
        // An install in progress owns the state and the release it's installing.
        guard state != .installing else { return }
        switch result {
        case .success(let release):
            let now = Date()
            lastChecked = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckedKey)
            if release.isUpdate(over: currentVersion), let version = release.version {
                self.release = release
                state = .available(version: version.description)
            } else {
                self.release = nil
                state = .upToDate
            }
        case .failure(let error):
            // Background checks fail silently; the next scheduled check retries.
            if userInitiated { state = .failed(error.message) }
        }
    }

    // MARK: - Installing

    func install() {
        guard let release, let asset = release.archive, state != .installing else { return }
        let appURL = Bundle.main.bundleURL
        state = .installing

        let workDir: URL
        do {
            // Same volume as the app, so the final swap is a rename rather than a copy.
            workDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: appURL, create: true)
        } catch {
            state = .failed(UpdateError.notWritable(appURL).message)
            return
        }

        openSession().downloadTask(with: asset.url) { [weak self] tempURL, response, error in
            guard let self else { return }
            defer { self.closeSession() }
            let zip = workDir.appendingPathComponent("Meowse.zip")
            guard error == nil, let tempURL, (response as? HTTPURLResponse)?.statusCode == 200,
                  (try? FileManager.default.moveItem(at: tempURL, to: zip)) != nil else {
                self.fail(.offline, cleaning: workDir)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let prepared = Result { try Self.prepare(zip: zip, digest: asset.digest, in: workDir, over: self.currentVersion) }
                DispatchQueue.main.async {
                    switch prepared {
                    case .success(let newApp):
                        self.swapAndRelaunch(appURL: appURL, newApp: newApp, workDir: workDir)
                    case .failure(let error):
                        self.fail(error as? UpdateError ?? .invalidArchive, cleaning: workDir)
                    }
                }
            }
        }.resume()
    }

    /// Off the main thread: checksum, unpack, and verify the new app.
    static func prepare(zip: URL, digest: String?, in workDir: URL, over current: Version) throws -> URL {
        if let digest, digest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard "sha256:" + hex == digest.lowercased() else { throw UpdateError.checksumMismatch }
        }

        let unpacked = workDir.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        let newApp = unpacked.appendingPathComponent("Meowse.app")
        var isDirectory: ObjCBool = false
        guard ditto.terminationStatus == 0,
              FileManager.default.fileExists(atPath: newApp.path, isDirectory: &isDirectory), isDirectory.boolValue,
              // A link would install a pointer to some other bundle, which could change after it's verified.
              (try? newApp.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false else {
            throw UpdateError.invalidArchive
        }

        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = Version(info?["CFBundleShortVersionString"] as? String ?? ""),
              version > current else {
            throw UpdateError.invalidArchive
        }
        try verifySignature(of: newApp)
        return newApp
    }

    /// The new app must be signed by the same team, for the same bundle ID, as this one.
    private static func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopySigningInformation(selfStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              let bundleID = Bundle.main.bundleIdentifier else {
            throw UpdateError.unsignedBuild
        }

        // Signed with Developer ID and notarized, as every release is. A build
        // signed for development, or one Apple hasn't checked, is refused.
        let rule = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and notarized"
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw UpdateError.badSignature
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.badSignature
        }
    }

    private func swapAndRelaunch(appURL: URL, newApp: URL, workDir: URL) {
        do {
            _ = try FileManager.default.replaceItemAt(appURL, withItemAt: newApp)
        } catch {
            fail(.notWritable(appURL), cleaning: workDir)
            return
        }
        try? FileManager.default.removeItem(at: workDir)
        NSApp.relaunch(appURL)
    }

    private func fail(_ error: UpdateError, cleaning workDir: URL) {
        try? FileManager.default.removeItem(at: workDir)
        state = .failed(error.message)
    }

    // MARK: - Session

    /// Ephemeral (no disk cache) and created per operation, so nothing lingers between checks.
    private func openSession() -> URLSession {
        if let session { return session }
        let s = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: .main)
        session = s
        return s
    }

    private func closeSession() {
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

private enum UpdateError: Error {
    case offline, noReleases, rateLimited, server(Int), malformed
    case checksumMismatch, invalidArchive, unsignedBuild, badSignature
    case notWritable(URL)

    var message: String {
        switch self {
        case .offline: return String(localized: "Couldn’t reach GitHub. Check your connection and try again.")
        case .noReleases: return String(localized: "No releases have been published yet.")
        case .rateLimited: return String(localized: "GitHub is limiting requests right now. Try again later.")
        case .server(let code): return String(localized: "GitHub returned an error (\(code)).")
        case .malformed: return String(localized: "The release information couldn’t be read.")
        case .checksumMismatch: return String(localized: "The download was corrupted. Try again.")
        case .invalidArchive: return String(localized: "The update package isn’t a valid Meowse release.")
        case .unsignedBuild: return String(localized: "This build isn’t signed, so it can’t verify updates. Install the new version manually.")
        case .badSignature: return String(localized: "The update isn’t signed by the Meowse developer, so it wasn’t installed.")
        case .notWritable(let url): return String(localized: "Meowse can’t replace itself at \(url.deletingLastPathComponent().path). Download the update from the release page.")
        }
    }
}
