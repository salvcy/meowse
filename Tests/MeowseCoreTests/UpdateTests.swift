import XCTest
@testable import MeowseCore

final class UpdateTests: XCTestCase {

    func testVersionParsing() {
        XCTAssertEqual(Version("1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(Version("v0.1")?.components, [0, 1])
        XCTAssertEqual(Version("2.0.0-beta.1")?.components, [2, 0, 0])
        XCTAssertNil(Version("latest"))
        XCTAssertNil(Version("1..2"))
        XCTAssertNil(Version(""))
    }

    func testVersionOrdering() {
        XCTAssertLessThan(Version("0.1.0")!, Version("0.2.0")!)
        XCTAssertLessThan(Version("0.9.9")!, Version("0.10.0")!)  // numeric, not lexical
        XCTAssertEqual(Version("1.0")!, Version("1.0.0")!)
        XCTAssertFalse(Version("1.0.0")! < Version("1")!)
    }

    private func release(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                         assets: String = #"[{"name":"Meowse.zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/Meowse.zip","size":700000,"digest":"sha256:abc"}]"#) throws -> Release {
        let json = """
        {"tag_name":"\(tag)","body":"Notes","html_url":"https://github.com/o/r/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(prerelease),"assets":\(assets),"unrelated":{"x":1}}
        """
        return try JSONDecoder().decode(Release.self, from: Data(json.utf8))
    }

    func testDecodesGitHubPayload() throws {
        let r = try release()
        XCTAssertEqual(r.version, Version("0.2.0"))
        XCTAssertEqual(r.archive?.name, "Meowse.zip")
        XCTAssertEqual(r.archive?.digest, "sha256:abc")
        XCTAssertEqual(r.notes, "Notes")
    }

    func testOffersOnlyNewerStableReleasesWithAnArchive() throws {
        let current = Version("0.1.0")!
        XCTAssertTrue(try release().isUpdate(over: current))
        XCTAssertFalse(try release(tag: "v0.1.0").isUpdate(over: current))
        XCTAssertFalse(try release(tag: "v0.0.9").isUpdate(over: current))
        XCTAssertFalse(try release(draft: true).isUpdate(over: current))
        XCTAssertFalse(try release(prerelease: true).isUpdate(over: current))
        XCTAssertFalse(try release(assets: "[]").isUpdate(over: current))
    }

    func testPrefersNamedArchive() throws {
        let r = try release(assets: #"""
        [{"name":"notes.txt","browser_download_url":"https://e.x/a","size":1},
         {"name":"Other.zip","browser_download_url":"https://e.x/b","size":2},
         {"name":"Meowse.zip","browser_download_url":"https://e.x/c","size":3}]
        """#)
        XCTAssertEqual(r.archive?.name, "Meowse.zip")
        XCTAssertNil(r.archive?.digest)
    }

    func testDownloadsOnlyFromTheRepositoryOnGitHub() throws {
        func asset(_ url: String) throws -> Release.Asset {
            try release(assets: #"[{"name":"Meowse.zip","browser_download_url":"\#(url)","size":1}]"#).archive!
        }
        XCTAssertTrue(try asset("https://github.com/o/r/releases/download/v0.2.0/Meowse.zip").isDownload(of: "o/r"))
        XCTAssertTrue(try asset("https://github.com/O/R/releases/download/v0.2.0/Meowse.zip").isDownload(of: "o/r"))
        XCTAssertFalse(try asset("http://github.com/o/r/releases/download/v0.2.0/Meowse.zip").isDownload(of: "o/r"))
        XCTAssertFalse(try asset("https://github.com.evil.example/o/r/releases/download/v0.2.0/Meowse.zip").isDownload(of: "o/r"))
        XCTAssertFalse(try asset("https://github.com@evil.example/o/r/releases/download/v0.2.0/Meowse.zip").isDownload(of: "o/r"))
        XCTAssertFalse(try asset("https://github.com/someone/else/releases/download/v0.2.0/Meowse.zip").isDownload(of: "o/r"))
        XCTAssertFalse(try asset("file:///tmp/Meowse.zip").isDownload(of: "o/r"))
    }
}
