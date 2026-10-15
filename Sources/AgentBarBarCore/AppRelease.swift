import Foundation
import CryptoKit

public struct AppRelease: Decodable, Sendable {
    public let tagName: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease, assets }

    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let browserDownloadURL: URL
        public let digest: String?
        enum CodingKeys: String, CodingKey { case name, size, digest; case browserDownloadURL = "browser_download_url" }
    }

    public static func versionParts(_ text: String) -> [Int]? {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let parts = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(field)
        }
        return parts.count == 3 ? parts : nil
    }

    public var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    public func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let latest = Self.versionParts(tagName), let installed = Self.versionParts(current) else { return false }
        return installed.lexicographicallyPrecedes(latest)
    }

    public func installer() throws -> Asset {
        guard !draft, !prerelease, Self.versionParts(tagName) != nil else { throw CoreError.invalid("Invalid release metadata") }
        let name = "AgentBarBar-\(version)-apple-silicon.dmg"
        let expected = "https://github.com/y2zyyr/AgentBarBar/releases/download/\(tagName)/\(name)"
        guard let asset = assets.first(where: { $0.name == name }), asset.size > 0,
              asset.browserDownloadURL.absoluteString == expected,
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CoreError.invalid("No verified compatible installer in this release")
        }
        return asset
    }

    /// Checks the downloaded file before moving it into Downloads. Never overwrites a user file.
    public static func saveInstaller(_ source: URL, asset: Asset, directory: URL) throws -> URL {
        guard asset.name == (asset.name as NSString).lastPathComponent, asset.name.hasSuffix(".dmg") else { throw CoreError.invalid("Invalid installer filename") }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == asset.size else { throw CoreError.invalid("Installer size mismatch") }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        let actual = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == asset.digest?.lowercased() else { throw CoreError.invalid("Installer checksum mismatch") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = (asset.name as NSString).deletingPathExtension
        var destination = directory.appendingPathComponent(asset.name)
        var number = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem) (\(number)).dmg"); number += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }
}
