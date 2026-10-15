import XCTest
import CryptoKit
@testable import AgentBarBarCore

final class AppReleaseTests: XCTestCase {
    private func release(version: String = "9.9.9", digest: String? = "sha256:" + String(repeating: "a", count: 64), url: String? = nil, prerelease: Bool = false, size: Int = 24) throws -> AppRelease {
        var asset: [String: Any] = ["name": "AgentBarBar-\(version)-apple-silicon.dmg", "size": size, "browser_download_url": url ?? "https://github.com/y2zyyr/AgentBarBar/releases/download/v\(version)/AgentBarBar-\(version)-apple-silicon.dmg"]
        if let digest { asset["digest"] = digest }
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v\(version)", "draft": false, "prerelease": prerelease, "assets": [asset]])
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    func testNumericVersionsAndStableChannel() throws {
        XCTAssertTrue(try release(version: "1.0.10").isNewer(than: "1.0.9"))
        XCTAssertTrue(try release(version: "1.0.2").isNewer(than: "1.0.1"))
        XCTAssertFalse(try release(version: "1.0.2").isNewer(than: "1.0.2"))
        XCTAssertFalse(try release(version: "1.0.1").isNewer(than: "1.0.2"))
        XCTAssertFalse(try release(prerelease: true).isNewer(than: "1.0.0"))
        for text in ["1.0", "1.0.2-beta", "1.-1.2", "1..2", "1.0.2/", "１.0.2"] { XCTAssertNil(AppRelease.versionParts(text)) }
    }

    func testInstallerRequiresTrustedURLAndIntegrityMetadata() throws {
        XCTAssertNoThrow(try release().installer())
        XCTAssertThrowsError(try release(digest: nil).installer())
        XCTAssertThrowsError(try release(digest: "sha256:bad").installer())
        XCTAssertThrowsError(try release(url: "https://example.invalid/update.dmg").installer())
        XCTAssertThrowsError(try release(prerelease: true).installer())
        XCTAssertThrowsError(try release(size: 0).installer())
    }

    func testDownloadedInstallerVerificationAndNoOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("anonymous installer fixture".utf8)
        let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try release(digest: digest, size: bytes.count).installer()
        let downloads = directory.appendingPathComponent("Downloads")
        let first = directory.appendingPathComponent("first.tmp")
        try bytes.write(to: first)
        let saved = try AppRelease.saveInstaller(first, asset: asset, directory: downloads)
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        let second = directory.appendingPathComponent("second.tmp")
        try bytes.write(to: second)
        let another = try AppRelease.saveInstaller(second, asset: asset, directory: downloads)
        XCTAssertNotEqual(saved, another)
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        let damaged = directory.appendingPathComponent("damaged.tmp")
        try Data(repeating: 0, count: bytes.count).write(to: damaged)
        XCTAssertThrowsError(try AppRelease.saveInstaller(damaged, asset: asset, directory: downloads))
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
        try Data([0]).write(to: damaged)
        XCTAssertThrowsError(try AppRelease.saveInstaller(damaged, asset: asset, directory: downloads))
    }
}
