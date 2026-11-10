import Foundation

/// A dotted numeric version ("1.2.3", "v1.2"). Missing components count as 0.
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        // Ignore pre-release/build suffixes: "1.2.0-beta.1" compares as 1.2.0.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.map { $0! }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.components.count, b.components.count) {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// The subset of the GitHub "latest release" payload Meowse uses.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int
        /// "sha256:<hex>", published by GitHub for release assets.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case url = "browser_download_url"
        }

        /// Whether it's a file of `repository`'s releases on GitHub, over
        /// HTTPS. The release information names the address, so it's checked
        /// before anything is fetched from it.
        public func isDownload(of repository: String) -> Bool {
            url.scheme == "https" && url.host == "github.com" && url.user == nil && url.port == nil
                && url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/")
        }
    }

    public let tag: String
    public let notes: String?
    public let page: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tag = "tag_name"
        case notes = "body"
        case page = "html_url"
    }

    public var version: Version? { Version(tag) }

    /// The app archive: "Meowse.zip" if present, otherwise the first .zip.
    public var archive: Asset? {
        assets.first { $0.name == "Meowse.zip" } ?? assets.first { $0.name.hasSuffix(".zip") }
    }

    /// Whether this release should be offered over `current`.
    public func isUpdate(over current: Version) -> Bool {
        guard !draft, !prerelease, let v = version, archive != nil else { return false }
        return v > current
    }
}
