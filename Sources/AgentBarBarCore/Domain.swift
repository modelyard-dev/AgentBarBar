import Foundation
import CryptoKit
import CoreFoundation

public enum MetricState: String, Codable, Sendable {
    case known, unknown, unsupported
    case notAvailable = "not_available"
    case partial
}

public struct Metric: Codable, Equatable, Sendable {
    public var value: Int64?
    public var state: MetricState
    public init(_ value: Int64? = nil, state: MetricState = .notAvailable) {
        self.value = value
        self.state = value == nil ? state : .known
    }
}

public struct TokenMetrics: Codable, Equatable, Sendable {
    public var input = Metric()
    public var output = Metric()
    public var cacheRead = Metric()
    public var cacheWrite = Metric()
    public var cachedOutput = Metric(state: .unsupported)
    public var reasoning = Metric()
    public var total = Metric()
    public init() {}
    public static let names = ["input", "output", "cacheRead", "cacheWrite", "cachedOutput", "reasoning", "total"]
    public var all: [String: Metric] {
        ["input": input, "output": output, "cacheRead": cacheRead, "cacheWrite": cacheWrite,
         "cachedOutput": cachedOutput, "reasoning": reasoning, "total": total]
    }
}

public struct ProjectIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var detectionMethod: String
    public var confidence: Double
}

public struct UsageEvent: Codable, Equatable, Sendable {
    public var id: String
    public var timestamp: String
    public var agentID: String
    public var agentName: String
    public var provider: String?
    public var model: String?
    public var rawModelName: String?
    public var sessionID: String?
    public var workingDirectory: String?
    public var project: ProjectIdentity?
    public var metrics: TokenMetrics
    public var cost: Double?
    public var currency: String?
    public var costState: MetricState = .notAvailable
    public var sourceType: String
    public var sourcePath: String
    public var sourceEventID: String
    public var sourceLine: Int
    public var sourceOffset: UInt64
    public var collectorID: String
    public var collectorVersion: String
    public var parserVersion: String
    public var isEstimated: Bool = false
    public var confidence: Double = 1
    public var quality: String = "exact"
    public var fingerprint: String
    public var sourceMetadata: [String: String]
    public var createdAt: String
}

public enum Capability: String, Codable, Sendable { case supported, conditional, unsupported, derived }
public struct CollectorDescriptor: Codable, Sendable {
    public var mode:String? = nil
    public var id: String
    public var agentID: String
    public var name: String
    public var version: String
    public var parserVersion: String
    public var supportedAgentVersions: [String]
    public var capabilities: [String: Capability]
    public var sourceRoots: [String]
    public var sourceDescription: String
}

public struct DetectionResult: Codable, Sendable {
    public var installed: Bool
    public var evidence: [String]
    public var sourceAvailable: Bool
    public var version: String?
    public var applicationPath: String?
    public init(installed: Bool, evidence: [String], sourceAvailable: Bool, version: String? = nil, applicationPath: String? = nil) {
        self.installed = installed; self.evidence = evidence; self.sourceAvailable = sourceAvailable
        self.version = version; self.applicationPath = applicationPath
    }
}

public struct CollectorHealth: Codable, Sendable {
    public var status: String = "waiting"
    public var lastCollection: String?
    public var compatibility: String = "unverified"
    public var reconciliation: Reconciliation?
    public var errors: [String] = []
    public var files: Int = 0
    public var bytesRead: UInt64 = 0
    public var imported: Int = 0
    public var updated: Int = 0
    public var duplicates: Int = 0
    public init() {}
}

/// Presentation severity does not change source coverage, counters, or retained errors.
public struct CollectorDiagnostic: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable { case info, warning, error }
    public var message: String
    public var severity: Severity
    public static func classify(_ message: String) -> Self {
        let information = [
            "Checked local log/schema metadata; no validated Token records. Conversation text, credits and quotas are not Token counts",
            "Candidate usage fields found; request identity, timestamps and semantics require validation",
            "No readable local usage directory was found in the checked rules",
            "History baseline unavailable: first cumulative snapshot exceeds last request",
            "Out-of-order cumulative snapshot ignored; legacy attribution coverage is partial",
            "Legacy cumulative component corrected by source; breakdown unavailable for this interval",
            "DeepSeek legacy cache counter is missing; input and total are Unknown"
        ]
        let severity: Severity
        if information.contains(message) { severity = .info }
        else if message == "Local usage reconciliation differs from source" || message.contains("Invalid source counters:") || message == "WorkBuddy source counters are inconsistent; reported values retained" || message == "DeepSeek component coverage differs from reported total; total retained" { severity = .warning }
        else { severity = .error }
        return Self(message: message, severity: severity)
    }
}

extension CollectorHealth {
    public var diagnostics: [CollectorDiagnostic] {
        var seen = Set<String>()
        return errors.filter { seen.insert($0).inserted }.map(CollectorDiagnostic.classify)
    }
    public var presentationStatus: String {
        status == "partial" && !diagnostics.isEmpty && diagnostics.allSatisfy { $0.severity == .info } ? "history_partial" : status
    }
}

public struct CollectionResult: Codable, Sendable {
    public var collectorID: String
    public var health: CollectorHealth
}

public struct MetricAggregate: Codable, Sendable {
    public var value: Int64?
    public var state: MetricState
    public var knownEvents: Int
    public var totalEvents: Int
}

public struct UsageSummary: Codable, Sendable {
    public var metrics: [String: MetricAggregate]
    public var events: Int
    public var sessions: Int
    public var agents: Int
    public var projects: Int
    public var activeAgents: Int
    public var estimatedEvents: Int
    public var cost: Double?
    public var costKnownEvents: Int
    public var currency: String?
    public var uncachedInput: MetricAggregate? = nil
}

public struct QueryFilter: Codable, Sendable {
    public var start: Double?
    public var end: Double?
    public var agent: String?
    public var model: String?
    public var project: String?
    public var provider: String?
    public var session: String?
    public var timeZone: String
    public init(start: Double? = nil, end: Double? = nil, agent: String? = nil, model: String? = nil,
                project: String? = nil, provider: String? = nil, session: String? = nil, timeZone: String = TimeZone.current.identifier) {
        self.start = start; self.end = end; self.agent = agent; self.model = model; self.project = project
        self.provider = provider; self.session = session; self.timeZone = timeZone
    }
}

public struct SourceCursor: Codable, Sendable {
    public var path: String
    public var identity: String
    public var offset: UInt64 = 0
    public var line: Int = 0
    public var modified: Double = 0
    public var state: ParserState = ParserState()
    public var parserVersion: String
    public var boundaryHash: String?
    public var observedSize: UInt64?
    public var lastError: String?
    public init(path: String, identity: String, parserVersion: String) {
        self.path = path; self.identity = identity; self.parserVersion = parserVersion
    }
}

public struct SourceThreadContext: Codable, Sendable {
    public var model:String?
    public var provider:String?
    public var cwd:String?
}
public struct ParserState: Codable, Sendable {
    public var threadContexts:[String:SourceThreadContext]?
    public var sessionID: String?
    public var cwd: String?
    public var model: String?
    public var provider: String?
    public var agentVersion: String?
    public var sourceEntrypoint: String?
    public var counters: [String: Int64]?
    public var preciseRequests: Bool?
    public var rootSessionID: String?
    public var forkedFrom: String?
    public var sessionRecordTimestamp: String?
    public var historyStartOrdinal: Int?
    public var warnings: [String] = []
    public var sourceRecordErrors: [String:String]?
    public var pendingSourceRows:[Int64]?
    public init() {}
    mutating func warn(_ warning: String) {
        if !warnings.contains(warning) && warnings.count < 8 { warnings.append(warning) }
    }
}

public enum CoreError: Error, LocalizedError {
    case invalid(String), database(String), io(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .database(let s), .io(let s): return s }
    }
}

public enum Utilities {
    private static let codec=DateCodec()
    public static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func date(_ text: String) -> Date? {
        codec.date(text)
    }
    public static func iso(_ date: Date = Date()) -> String {
        codec.iso(date)
    }
    public static func json<T: Encodable>(_ object: T) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return String(decoding: try e.encode(object), as: UTF8.self)
    }
    public static func token(_ obj: [String: Any], _ key: String) throws -> Int64? {
        guard let raw = obj[key], !(raw is NSNull) else { return nil }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              n.doubleValue.rounded() == n.doubleValue else { throw CoreError.invalid("Parser incompatible: invalid token field \(key)") }
        return n.int64Value
    }
    public static func sourceUsage(_ obj: [String: Any]) -> String {
        // No arbitrary source JSON is persisted; only explicitly named numeric counters.
        let keys = ["input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "reasoning_output_tokens", "total_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "input", "output", "cacheRead", "cacheWrite", "totalTokens", "reasoning"]
        var clean: [String: Int64] = [:]
        for k in keys { if let v = try? token(obj, k) { clean[k] = v } }
        if let detail = obj["output_tokens_details"] as? [String: Any], let v = try? token(detail, "thinking_tokens") { clean["thinking_tokens"] = v }
        return (try? json(clean)) ?? "{}"
    }
}

private final class DateCodec:@unchecked Sendable {
    private let lock=NSLock()
    private let fractional=ISO8601DateFormatter()
    private let whole=ISO8601DateFormatter()
    init() {fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds];whole.formatOptions=[.withInternetDateTime]}
    func date(_ value:String) -> Date? {lock.lock();defer{lock.unlock()};return fractional.date(from:value) ?? whole.date(from:value)}
    func iso(_ value:Date) -> String {lock.lock();defer{lock.unlock()};return fractional.string(from:value)}
}

public final class ProjectDetector {
    private var cache: [String: ProjectIdentity?] = [:]
    public init() {}
    public func detect(cwd: String?) -> ProjectIdentity? {
        guard let cwd, cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        if let stored = cache[cwd] { return stored }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path != home, path != "/", !path.hasPrefix("/private/var/"), !path.hasPrefix("/tmp/"),
              !path.hasPrefix("/System/"), !path.hasPrefix("/Library/") else { cache[cwd] = .some(nil); return nil }
        var candidate = URL(fileURLWithPath: path)
        while candidate.path != "/", candidate.path != home {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                let p = ProjectIdentity(id: Utilities.hash(candidate.path), name: candidate.lastPathComponent,
                                        path: candidate.path, detectionMethod: "git_root_from_session_cwd", confidence: 0.95)
                cache[cwd] = p; return p
            }
            candidate.deleteLastPathComponent()
        }
        let p = ProjectIdentity(id: Utilities.hash(path), name: URL(fileURLWithPath: path).lastPathComponent,
                                path: path, detectionMethod: "explicit_session_cwd", confidence: 0.8)
        cache[cwd] = p; return p
    }
}
