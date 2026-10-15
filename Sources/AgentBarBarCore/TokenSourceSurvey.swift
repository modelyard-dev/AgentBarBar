import Foundation
import CSQLite

public struct TokenSourceSurvey: Codable, Sendable {
    public struct Finding: Codable, Sendable {
        public var path: String
        public var format: String
        public var fields: [String]
        public var status: String
    }
    public var version = "token-source-survey-v1.0.0"
    public var agentID: String
    public var checkedAt: String
    public var roots: [String]
    public var filesChecked = 0
    public var bytesRead = 0
    public var limited = false
    public var findings: [Finding] = []
    public var errors: [String] = []
    public var verifiedParser: String?
    public var knownEvents: Int?
    public var collectionStatus: String = "not_collected"

    /// Bounded, user-initiated search. Only field names and paths survive this call.
    public static func inspect(agentID: String, roots: [String], fileLimit: Int = 256, byteLimit: Int = 16 * 1024 * 1024) -> Self {
        var report = Self(agentID: agentID, checkedAt: Utilities.iso(), roots: Array(Set(roots)).sorted())
        let fm = FileManager.default
        let started = Date()
        let excluded = ["auth", "credential", "secret", "cookie", "preferences", "config", "settings", "local state", "session storage", "local storage", "node_modules", "cache", ".git", "login", "keychain"]
        let fields = ["input_tokens", "output_tokens", "prompt_tokens", "completion_tokens", "total_tokens", "cached_input_tokens", "cache_read_input_tokens", "reasoning_tokens", "inputTokens", "outputTokens", "totalTokens", "tokenCount", "usageMetadata", "tokenUsage", "promptTokenCount", "candidatesTokenCount", "totalTokenCount"]
        var visited = Set<String>()
        for root in report.roots {
            let url = URL(fileURLWithPath: root).standardizedFileURL
            guard url.path != "/", url.path != fm.homeDirectoryForCurrentUser.path else { report.errors.append("Survey root is too broad: " + root); continue }
            guard url.resolvingSymlinksInPath().path == url.path else { report.errors.append("Symbolic source root skipped: " + root); continue }
            guard fm.fileExists(atPath: root) else { continue }
            guard fm.isReadableFile(atPath: root) else { report.errors.append("Permission denied: " + root); continue }
            guard let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            while let file = iterator.nextObject() as? URL {
                if report.filesChecked >= fileLimit || report.bytesRead >= byteLimit || Date().timeIntervalSince(started) > 5 { report.limited = true; return report }
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if iterator.level > 6 || values?.isSymbolicLink == true || excluded.contains(where: { file.lastPathComponent.lowercased().contains($0) }) { iterator.skipDescendants(); continue }
                guard values?.isRegularFile == true, visited.insert(file.path).inserted else { continue }
                report.filesChecked += 1
                let ext = file.pathExtension.lowercased()
                if ["sqlite", "db", "vscdb"].contains(ext) {
                    do {
                        let db = try ReadOnlySourceDatabase(path: file.path)
                        let statement = try db.prepare("SELECT sql FROM sqlite_master WHERE type='table'")
                        defer { sqlite3_finalize(statement) }
                        var found = Set<String>(); var count = 0
                        while sqlite3_step(statement) == SQLITE_ROW, count < 256 {
                            count += 1
                            let schema = db.string(statement, 0) ?? ""
                            fields.filter { schema.contains($0) }.forEach { found.insert($0) }
                        }
                        if !found.isEmpty { report.findings.append(.init(path: file.path, format: "SQLite schema", fields: found.sorted(), status: "candidate_source")) }
                    } catch { report.errors.append("Cannot inspect source schema: " + file.path) }
                } else if ["json", "jsonl", "log"].contains(ext)
                    || (agentID == "claude-desktop"
                        && (file.path.contains("/IndexedDB/") || file.path.contains("/local-agent-mode-sessions/"))
                        && (ext.isEmpty || ["ldb", "sst"].contains(ext))) {
                    do {
                        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                        let amount = min(1024 * 1024, byteLimit - report.bytesRead)
                        let data = try handle.read(upToCount: amount) ?? Data()
                        report.bytesRead += data.count
                        if (values?.fileSize ?? 0) > data.count { report.limited = true }
                        // Key markers are evidence, not verified usage. Never retain values or raw lines.
                        let found = fields.filter { data.range(of: Data(("\"" + $0 + "\"").utf8)) != nil }
                        if !found.isEmpty { report.findings.append(.init(path: file.path, format: ext.uppercased(), fields: found, status: "candidate_source")) }
                    } catch { report.errors.append("Cannot inspect source file: " + file.path) }
                }
            }
        }
        return report
    }
}
