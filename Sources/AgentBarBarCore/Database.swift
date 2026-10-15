import Foundation
import CSQLite

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum SQLValue { case text(String), integer(Int64), real(Double), null }

private final class SQLDatabase {
    var handle: OpaquePointer?
    init(path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CoreError.database("Cannot open AgentBarBar database")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> CoreError { .database("Database error: " + String(cString: sqlite3_errmsg(handle))) }
    func prepare(_ sql: String, _ args: [SQLValue] = []) throws -> OpaquePointer {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &p, nil) == SQLITE_OK, let p else { throw error() }
        for (i,v) in args.enumerated() {
            let rc: Int32
            switch v {
            case .text(let s): rc = sqlite3_bind_text(p, Int32(i+1), s, -1, transient)
            case .integer(let n): rc = sqlite3_bind_int64(p, Int32(i+1), n)
            case .real(let n): rc = sqlite3_bind_double(p, Int32(i+1), n)
            case .null: rc = sqlite3_bind_null(p, Int32(i+1))
            }
            if rc != SQLITE_OK { sqlite3_finalize(p); throw error() }
        }
        return p
    }
    @discardableResult func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let p = try prepare(sql,args); defer { sqlite3_finalize(p) }
        guard sqlite3_step(p) == SQLITE_DONE else { throw error() }; return Int(sqlite3_changes(handle))
    }
    func string(_ p: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(p,index) != SQLITE_NULL, let text = sqlite3_column_text(p,index) else { return nil }
        return String(cString: text)
    }
}

public struct GroupRow: Codable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var lastActivity: String?
    public var models: [String]
    public var agentIDs: [String]
    public var projectIDs: [String]
    public var summary: UsageSummary
}
public struct TimelinePoint: Codable, Sendable {
    public var timestamp: String
    public var end: String
    public var summary: UsageSummary
}
public struct OverviewResponse: Codable, Sendable {
    public var selected: UsageSummary
    public var today: UsageSummary
    public var sevenDays: UsageSummary
    public var thirtyDays: UsageSummary
    public var allTime: UsageSummary
    public var yesterday: UsageSummary
    public var changePercent: Double?
    public var timeline: [TimelinePoint]
    public var agentDistribution: [GroupRow]
    public var modelDistribution: [GroupRow]
    public var timeZone: String
}
public struct EventPage: Codable, Sendable {
    public var events: [UsageEvent]
    public var total: Int
    public var offset: Int
    public var limit: Int
}
public struct CollectorRecord: Codable, Sendable {
    public var descriptor: CollectorDescriptor
    public var detection: DetectionResult
    public var health: CollectorHealth
    public var enabled: Bool
    public var diagnostics: [CollectorDiagnostic]?
    public var presentationStatus: String?
    public var coverage: SourceCoverage?
    public init(descriptor: CollectorDescriptor, detection: DetectionResult, health: CollectorHealth, enabled: Bool) {
        self.descriptor = descriptor; self.detection = detection; self.health = health; self.enabled = enabled
        self.diagnostics = health.diagnostics; self.presentationStatus = health.presentationStatus
    }
}
public struct AgentRecord: Codable, Sendable {
    public var id: String
    public var name: String
    public var detection: DetectionResult
    public var collector: CollectorRecord?
    public var summary: UsageSummary
    public var today: UsageSummary
    public var allTime: UsageSummary
    public var lastSeen: String?
    public var models: [String]
    public var projects: [String]
}
public struct AgentIdentity: Sendable {
    public var id:String
    public var name:String
    public var detection:DetectionResult
}
public struct FilterOptions: Codable, Sendable {
    public var agents: [Option]
    public var models: [Option]
    public var projects: [Option]
    public var providers: [Option]
    public struct Option: Codable, Sendable { public var id: String; public var name: String }
}
public struct CommitResult: Codable, Sendable {
    public var inserted = 0
    public var updated = 0
    public var duplicates = 0
}
public struct MenuSnapshot:Codable,Sendable {
    public var today:UsageSummary
    public var yesterday:UsageSummary
    public var agents:[GroupRow]
    public var models:[GroupRow]
    public var changePercent:Double?
}

public actor EventStore {
    private var dashboardRevision:UInt64=0
    public func cacheRevision() -> UInt64 {dashboardRevision}

    public static let schemaVersion = 7
    public let path: String
    private let db: SQLDatabase
    public init(path: String) throws {
        self.path = path; db = try SQLDatabase(path:path)
        try Self.migrate(db)
    }
    private static func migrate(_ db: SQLDatabase) throws {
        let p = try db.prepare("PRAGMA user_version"); sqlite3_step(p)
        let old = Int(sqlite3_column_int(p,0)); sqlite3_finalize(p)
        guard old <= schemaVersion else { throw CoreError.database("Database schema is newer than this app; use a newer AgentBarBar") }
        try db.execute("BEGIN IMMEDIATE")
        do {
            if old < 1 {
                try db.execute("""
                CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
                CREATE TABLE agents(id TEXT PRIMARY KEY, name TEXT NOT NULL, detection_json TEXT NOT NULL);
                CREATE TABLE collectors(id TEXT PRIMARY KEY, agent_id TEXT NOT NULL REFERENCES agents(id), descriptor_json TEXT NOT NULL, health_json TEXT NOT NULL);
                CREATE TABLE models(id TEXT PRIMARY KEY, raw_name TEXT NOT NULL);
                CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, detection_method TEXT NOT NULL, confidence REAL NOT NULL);
                CREATE TABLE sessions(id TEXT PRIMARY KEY, raw_id TEXT NOT NULL, agent_id TEXT NOT NULL REFERENCES agents(id));
                CREATE TABLE usage_events(
                  id TEXT PRIMARY KEY, timestamp REAL NOT NULL, agent_id TEXT NOT NULL REFERENCES agents(id),
                  model TEXT, provider TEXT, session_id TEXT, project_id TEXT REFERENCES projects(id),
                  input_tokens INTEGER, output_tokens INTEGER, cached_input_tokens INTEGER, cache_write_tokens INTEGER,
                  cached_output_tokens INTEGER, reasoning_tokens INTEGER, total_tokens INTEGER,
                  cost REAL, currency TEXT, is_estimated INTEGER NOT NULL, source_event_id TEXT NOT NULL UNIQUE,
                  fingerprint TEXT NOT NULL UNIQUE, source_path TEXT NOT NULL, collector_id TEXT NOT NULL,
                  event_json TEXT NOT NULL, created_at TEXT NOT NULL,
                  CHECK(input_tokens IS NULL OR input_tokens >= 0), CHECK(output_tokens IS NULL OR output_tokens >= 0),
                  CHECK(total_tokens IS NULL OR total_tokens >= 0)
                );
                CREATE TABLE collection_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, collector_id TEXT NOT NULL, started_at TEXT NOT NULL, finished_at TEXT, result_json TEXT);
                CREATE TABLE settings(key TEXT PRIMARY KEY, value_json TEXT NOT NULL);
                CREATE TABLE source_cursors(path TEXT PRIMARY KEY, collector_id TEXT NOT NULL, cursor_json TEXT NOT NULL);
                CREATE INDEX usage_timestamp ON usage_events(timestamp);
                CREATE INDEX usage_agent ON usage_events(agent_id,timestamp);
                CREATE INDEX usage_model ON usage_events(model,timestamp);
                CREATE INDEX usage_session ON usage_events(agent_id,session_id,timestamp);
                CREATE INDEX usage_project ON usage_events(project_id,timestamp);
                INSERT INTO schema_migrations VALUES(1,datetime('now'));
                PRAGMA user_version=1;
                """)
            }
            if old < 2 {
                try db.execute("""
                CREATE INDEX usage_provider ON usage_events(provider,timestamp);
                CREATE INDEX cursor_collector ON source_cursors(collector_id);
                CREATE INDEX run_collector ON collection_runs(collector_id,id);
                INSERT INTO schema_migrations VALUES(2,datetime('now'));
                PRAGMA user_version=2;
                """)
            }
            if old < 3 {
                for name in TokenMetrics.names {try db.execute("ALTER TABLE usage_events ADD COLUMN \(name)_state TEXT NOT NULL DEFAULT 'not_available'")}
                let assignments=TokenMetrics.names.map{"\($0)_state=COALESCE(json_extract(event_json,'$.metrics.\($0).state'),'not_available')"}.joined(separator:",")
                try db.execute("UPDATE usage_events SET \(assignments)")
                try db.execute("CREATE INDEX usage_session_direct ON usage_events(session_id,timestamp); INSERT INTO schema_migrations VALUES(3,datetime('now')); PRAGMA user_version=3;")
            }
            if old < 4 {
                // Earlier snapshots could retain the first streaming timestamp in SQL but the final timestamp in JSON.
                // Events are normalized to millisecond UTC ISO strings; reconcile to the final reported snapshot.
                try db.execute("""
                UPDATE usage_events SET timestamp=CAST(strftime('%s',json_extract(event_json,'$.timestamp')) AS REAL)
                  + CAST(substr(json_extract(event_json,'$.timestamp'),21,3) AS REAL)/1000.0;
                INSERT INTO schema_migrations VALUES(4,datetime('now'));
                PRAGMA user_version=4;
                """)
            }
            if old < 5 {
                // Counter queries must not read large provenance JSON pages for every historical request.
                // This is an index in AgentBarBar's own store; Agent source databases stay read-only.
                try db.execute("""
                CREATE INDEX usage_aggregation ON usage_events(
                  agent_id,timestamp,model,provider,project_id,session_id,
                  input_tokens,output_tokens,cached_input_tokens,cache_write_tokens,cached_output_tokens,
                  reasoning_tokens,total_tokens,cost,currency,is_estimated,
                  input_state,output_state,cacheRead_state,cacheWrite_state,cachedOutput_state,reasoning_state,total_state);
                INSERT INTO schema_migrations VALUES(5,datetime('now'));
                PRAGMA user_version=5;
                """)
            }
            if old < 6 {
                try db.execute("""
                CREATE TABLE superseded_usage_events AS SELECT *, '' AS superseded_at FROM usage_events WHERE 0;
                DROP INDEX usage_aggregation;
                CREATE INDEX usage_aggregation ON usage_events(
                  agent_id,timestamp,model,provider,project_id,session_id,
                  input_tokens,output_tokens,cached_input_tokens,cache_write_tokens,cached_output_tokens,
                  reasoning_tokens,total_tokens,cost,currency,is_estimated,
                  input_state,output_state,cacheRead_state,cacheWrite_state,cachedOutput_state,reasoning_state,total_state,source_event_id);
                INSERT INTO schema_migrations VALUES(6,datetime('now'));
                PRAGMA user_version=6;
                """)
            }
            if old < 7 {
                try db.execute("""
                CREATE TABLE usage_staging(run_id INTEGER,source_event_id TEXT,event_json TEXT NOT NULL,PRIMARY KEY(run_id,source_event_id));
                CREATE TABLE cursor_staging(run_id INTEGER,path TEXT,cursor_json TEXT NOT NULL,PRIMARY KEY(run_id,path));
                INSERT INTO schema_migrations VALUES(7,datetime('now')); PRAGMA user_version=7;
                """)
            }
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
    public func migrationVersion() throws -> Int {
        let p = try db.prepare("PRAGMA user_version"); defer { sqlite3_finalize(p) }; sqlite3_step(p); return Int(sqlite3_column_int(p,0))
    }
    public func setting<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        let p = try db.prepare("SELECT value_json FROM settings WHERE key=?",[.text(key)]); defer { sqlite3_finalize(p) }
        guard sqlite3_step(p) == SQLITE_ROW, let s = db.string(p,0) else { return nil }
        return try JSONDecoder().decode(type,from:Data(s.utf8))
    }
    public func setSetting<T: Encodable>(_ key: String, value: T) throws {
        dashboardRevision &+= 1
        try db.run("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json",[.text(key),.text(try Utilities.json(value))])
    }
    public func registerAgent(id: String, name: String, detection: DetectionResult) throws {
        dashboardRevision &+= 1
        try db.run("INSERT INTO agents VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,detection_json=excluded.detection_json",[.text(id),.text(name),.text(try Utilities.json(detection))])
    }
    public func updateAgentDetection(id:String,detection:DetectionResult) throws {
        dashboardRevision &+= 1
        try db.run("UPDATE agents SET detection_json=? WHERE id=?",[.text(try Utilities.json(detection)),.text(id)])
    }
    public func registerCollector(_ descriptor: CollectorDescriptor, detection: DetectionResult, health: CollectorHealth) throws {
        try registerAgent(id:descriptor.agentID,name:descriptor.name,detection:detection)
        try db.run("INSERT INTO collectors VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET descriptor_json=excluded.descriptor_json,health_json=excluded.health_json",[.text(descriptor.id),.text(descriptor.agentID),.text(try Utilities.json(descriptor)),.text(try Utilities.json(health))])
    }
    public func updateHealth(_ id: String, _ health: CollectorHealth) throws {
        dashboardRevision &+= 1
        try db.run("UPDATE collectors SET health_json=? WHERE id=?",[.text(try Utilities.json(health)),.text(id)])
    }
    public func retireCustomCollectors(active:[String]) throws {
        let p=try db.prepare("SELECT id,health_json FROM collectors WHERE id LIKE 'custom-%'");defer{sqlite3_finalize(p)}
        var retired:[(String,CollectorHealth)]=[]
        while sqlite3_step(p)==SQLITE_ROW {
            if let id=db.string(p,0),!active.contains(id),let text=db.string(p,1),var health=try? JSONDecoder().decode(CollectorHealth.self,from:Data(text.utf8)) {
                health.status="removed";retired.append((id,health))
            }
        }
        for (id,health) in retired {try updateHealth(id,health)}
    }
    public func cursor(path: String) throws -> SourceCursor? {
        let p=try db.prepare("SELECT cursor_json FROM source_cursors WHERE path=?",[.text(path)]); defer { sqlite3_finalize(p) }
        guard sqlite3_step(p)==SQLITE_ROW,let s=db.string(p,0) else { return nil }
        return try JSONDecoder().decode(SourceCursor.self,from:Data(s.utf8))
    }
    public func cursorCount() throws -> Int {
        let p=try db.prepare("SELECT count(*) FROM source_cursors"); defer { sqlite3_finalize(p) }; sqlite3_step(p); return Int(sqlite3_column_int(p,0))
    }
    public func beginRun(collectorID: String) throws -> Int64 {
        try db.run("INSERT INTO collection_runs(collector_id,started_at) VALUES(?,?)",[.text(collectorID),.text(Utilities.iso())]); return sqlite3_last_insert_rowid(db.handle)
    }
    public func finishRun(_ id: Int64, result: CollectionResult) throws {
        try db.run("UPDATE collection_runs SET finished_at=?, result_json=? WHERE id=?",[.text(Utilities.iso()),.text(try Utilities.json(result)),.integer(id)])
        // Bound diagnostic history; event history is never automatically deleted.
        try db.run("DELETE FROM collection_runs WHERE id < (SELECT COALESCE(MAX(id),0)-1000 FROM collection_runs)")
    }
    public func commit(events: [UsageEvent], cursor: SourceCursor? = nil, collectorID: String? = nil,
                       authoritativeAgent: String? = nil, replaceAgent: Bool = false,
                       removedSourceIDs: [String] = [], expectedCount: Int? = nil, expectedTotal: Int64? = nil) throws -> CommitResult {
        try db.execute("BEGIN IMMEDIATE")
        do {
            var result = CommitResult()
            if let agent = authoritativeAgent {
                guard events.allSatisfy({ $0.agentID == agent }) else { throw CoreError.invalid("Authoritative source scope mismatch") }
                if replaceAgent {
                    // Keep the prior metadata for recovery; only the active statistics are superseded.
                    try db.run("INSERT INTO superseded_usage_events SELECT *, ? FROM usage_events WHERE agent_id=?",[.text(Utilities.iso()),.text(agent)])
                    try db.run("DELETE FROM usage_events WHERE agent_id=?",[.text(agent)])
                }
                for sourceID in removedSourceIDs { try db.run("DELETE FROM usage_events WHERE agent_id=? AND source_event_id=?",[.text(agent),.text(sourceID)]) }
            }
            for e in events {
                // A restored old rollout must replace its retained legacy identity, not add a second request.
                if e.agentID=="codex",let response=e.sourceMetadata["response_id"] {
                    let legacy="codex:response:"+response
                    let alias=try db.prepare("SELECT event_json FROM usage_events WHERE source_event_id=?",[.text(legacy)])
                    let encoded=sqlite3_step(alias)==SQLITE_ROW ? db.string(alias,0):nil;sqlite3_finalize(alias)
                    if let encoded,let old=try? JSONDecoder().decode(UsageEvent.self,from:Data(encoded.utf8)),old.sessionID==e.sessionID,old.sourceMetadata["coverage_notes"]?.contains("no longer present")==true {
                        try db.run("INSERT INTO superseded_usage_events SELECT *,? FROM usage_events WHERE source_event_id=?",[.text(Utilities.iso()),.text(legacy)])
                        try db.run("DELETE FROM usage_events WHERE source_event_id=?",[.text(legacy)])
                    }
                }
                let existing=try db.prepare("SELECT total_tokens,event_json FROM usage_events WHERE source_event_id=? OR fingerprint=?",[.text(e.sourceEventID),.text(e.fingerprint)])
                let present=sqlite3_step(existing)==SQLITE_ROW
                let previousTotal = present && sqlite3_column_type(existing,0) != SQLITE_NULL ? sqlite3_column_int64(existing,0) : nil
                let oldJSON = present ? db.string(existing,1) : nil
                sqlite3_finalize(existing)
                if present {
                    let old = oldJSON.flatMap { try? JSONDecoder().decode(UsageEvent.self,from:Data($0.utf8)) }
                    // Migration snapshots can survive under a different name/root. Once
                    // a Gemini message has stream provenance, an old JSON snapshot
                    // cannot overwrite its counters on a later change notification.
                    if e.agentID=="gemini",old?.sourceType=="local_session_jsonl",e.sourceType=="local_session_json" {
                        result.duplicates += 1;continue
                    }
                    let betterTotal = e.metrics.total.value.map { $0 > (previousTotal ?? -1) } ?? false
                    let improvedMetric = old.map { old in TokenMetrics.names.contains { old.metrics.all[$0]?.value == nil && e.metrics.all[$0]?.value != nil } } ?? false
                    let improvedMetadata=old.map{($0.rawModelName==nil && e.rawModelName != nil) || ($0.provider==nil && e.provider != nil) || ($0.project==nil && e.project != nil) || $0.parserVersion != e.parserVersion || ($0.sourcePath != e.sourcePath && !FileManager.default.fileExists(atPath:$0.sourcePath))} ?? false
                    if authoritativeAgent == nil && !betterTotal && !improvedMetric && !improvedMetadata { result.duplicates += 1; continue }
                    // A smaller streaming snapshot must not overwrite a completed request.
                    if authoritativeAgent == nil, let a=previousTotal, let b=e.metrics.total.value, b<a { result.duplicates += 1; continue }
                }
                let detection=DetectionResult(installed:true,evidence:["usage_source"],sourceAvailable:true)
                try db.run("INSERT OR IGNORE INTO agents VALUES(?,?,?)",[.text(e.agentID),.text(e.agentName),.text(try Utilities.json(detection))])
                if let m=e.rawModelName { try db.run("INSERT OR IGNORE INTO models VALUES(?,?)",[.text(m),.text(m)]) }
                if let p=e.project {
                    try db.run("INSERT INTO projects VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,path=excluded.path,detection_method=excluded.detection_method,confidence=excluded.confidence",
                               [.text(p.id),.text(p.name),.text(p.path),.text(p.detectionMethod),.real(p.confidence)])
                }
                if let s=e.sessionID { try db.run("INSERT OR IGNORE INTO sessions VALUES(?,?,?)",[.text(e.agentID+":"+s),.text(s),.text(e.agentID)]) }
                let strings: (String?) -> SQLValue = { $0.map(SQLValue.text) ?? .null }
                let integer: (Int64?) -> SQLValue = { $0.map(SQLValue.integer) ?? .null }
                var args: [SQLValue] = [.text(e.id),.real(Utilities.date(e.timestamp)!.timeIntervalSince1970),.text(e.agentID),strings(e.rawModelName),strings(e.provider),strings(e.sessionID),strings(e.project?.id),
                                        integer(e.metrics.input.value),integer(e.metrics.output.value),integer(e.metrics.cacheRead.value),integer(e.metrics.cacheWrite.value),integer(e.metrics.cachedOutput.value),integer(e.metrics.reasoning.value),integer(e.metrics.total.value),
                                        e.cost.map(SQLValue.real) ?? .null,strings(e.currency),.integer(e.isEstimated ? 1:0),.text(e.sourceEventID),.text(e.fingerprint),.text(e.sourcePath),.text(e.collectorID),.text(try Utilities.json(e)),.text(e.createdAt)]
                args += TokenMetrics.names.map{.text(e.metrics.all[$0]!.state.rawValue)}
                try db.run("""
                INSERT INTO usage_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_event_id) DO UPDATE SET
                 timestamp=excluded.timestamp,model=excluded.model,provider=excluded.provider,session_id=excluded.session_id,
                 project_id=excluded.project_id,source_path=excluded.source_path,input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens,
                 cached_input_tokens=excluded.cached_input_tokens,cache_write_tokens=excluded.cache_write_tokens,
                 cached_output_tokens=excluded.cached_output_tokens,reasoning_tokens=excluded.reasoning_tokens,total_tokens=excluded.total_tokens,
                 cost=excluded.cost,currency=excluded.currency,event_json=excluded.event_json,
                 input_state=excluded.input_state,output_state=excluded.output_state,cacheRead_state=excluded.cacheRead_state,
                 cacheWrite_state=excluded.cacheWrite_state,cachedOutput_state=excluded.cachedOutput_state,
                 reasoning_state=excluded.reasoning_state,total_state=excluded.total_state
                """,args)
                if present { result.updated += 1 } else { result.inserted += 1 }
            }
            if let agent = authoritativeAgent, let expectedCount, let expectedTotal {
                let check = try db.prepare("SELECT COUNT(*),COALESCE(SUM(total_tokens),0) FROM usage_events WHERE agent_id=?",[.text(agent)])
                defer { sqlite3_finalize(check) }
                guard sqlite3_step(check)==SQLITE_ROW, sqlite3_column_int64(check,0)==Int64(expectedCount), sqlite3_column_int64(check,1)==expectedTotal else {
                    throw CoreError.invalid("Authoritative ledger reconciliation mismatch")
                }
            }
            if let cursor, let collectorID {
                try db.run("INSERT INTO source_cursors VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET collector_id=excluded.collector_id,cursor_json=excluded.cursor_json",[.text(cursor.path),.text(collectorID),.text(try Utilities.json(cursor))])
            }
            try db.execute("COMMIT"); if result.inserted>0 || result.updated>0 || replaceAgent || !removedSourceIDs.isEmpty {dashboardRevision &+= 1}; return result
        } catch { try? db.execute("ROLLBACK"); throw error }
    }
    public func usesOldParserRows(agentID:String,version:String) throws -> Bool {
        let p=try db.prepare("SELECT 1 FROM usage_events WHERE agent_id=? AND json_extract(event_json,'$.parserVersion')!=? LIMIT 1",[.text(agentID),.text(version)])
        defer{sqlite3_finalize(p)};return sqlite3_step(p)==SQLITE_ROW
    }
    public func stageReplacement(run: Int64, events: [UsageEvent], cursor: SourceCursor) throws -> CommitResult {
        try db.execute("BEGIN IMMEDIATE")
        do {
            var result=CommitResult()
            for event in events {
                let previous=try db.prepare("SELECT event_json FROM usage_staging WHERE run_id=? AND source_event_id=?",[.integer(run),.text(event.sourceEventID)])
                let encoded=sqlite3_step(previous)==SQLITE_ROW ? db.string(previous,0):nil;sqlite3_finalize(previous)
                if let encoded,let old=try? JSONDecoder().decode(UsageEvent.self,from:Data(encoded.utf8)) {
                    let oldOwner=old.sourceMetadata["owner_matches_file"]=="true",newOwner=event.sourceMetadata["owner_matches_file"]=="true"
                    if (oldOwner && !newOwner) || (old.metrics.total.value ?? -1)>(event.metrics.total.value ?? -1) {result.duplicates+=1;continue}
                    result.updated+=1
                } else {result.inserted+=1}
                try db.run("INSERT INTO usage_staging VALUES(?,?,?) ON CONFLICT(run_id,source_event_id) DO UPDATE SET event_json=excluded.event_json",[.integer(run),.text(event.sourceEventID),.text(try Utilities.json(event))])
            }
            try db.run("INSERT INTO cursor_staging VALUES(?,?,?) ON CONFLICT(run_id,path) DO UPDATE SET cursor_json=excluded.cursor_json",[.integer(run),.text(cursor.path),.text(try Utilities.json(cursor))])
            try db.execute("COMMIT"); return result
        } catch {try? db.execute("ROLLBACK");throw error}
    }
    public func discardReplacement(run: Int64) throws {
        try db.run("DELETE FROM usage_staging WHERE run_id=?",[.integer(run)])
        try db.run("DELETE FROM cursor_staging WHERE run_id=?",[.integer(run)])
    }
    public func preserveMissingHistory(run:Int64,agentID:String) throws {
        let paths=try db.prepare("SELECT DISTINCT source_path FROM usage_events WHERE agent_id=?",[.text(agentID)])
        var missing:[String]=[]
        while sqlite3_step(paths)==SQLITE_ROW {if let path=db.string(paths,0),!FileManager.default.fileExists(atPath:path) {missing.append(path)}}
        sqlite3_finalize(paths)
        for path in missing {
            let p=try db.prepare("SELECT event_json FROM usage_events WHERE agent_id=? AND source_path=?",[.text(agentID),.text(path)])
            defer{sqlite3_finalize(p)}
            while sqlite3_step(p)==SQLITE_ROW {
                guard let json=db.string(p,0),var event=try? JSONDecoder().decode(UsageEvent.self,from:Data(json.utf8)) else{continue}
                let prefix=agentID+":response:"
                if event.sourceEventID.hasPrefix(prefix),let owner=event.sessionID {
                    let key=agentID+":thread:"+owner+":response:"+String(event.sourceEventID.dropFirst(prefix.count))
                    let exists=try db.prepare("SELECT 1 FROM usage_staging WHERE run_id=? AND source_event_id=?",[.integer(run),.text(key)])
                    let present=sqlite3_step(exists)==SQLITE_ROW;sqlite3_finalize(exists)
                    if present {continue}
                }
                event.sourceMetadata["coverage_notes"]="Previously collected source is no longer present; retained metadata is not reverified"
                try db.run("INSERT OR IGNORE INTO usage_staging VALUES(?,?,?)",[.integer(run),.text(event.sourceEventID),.text(try Utilities.json(event))])
            }
        }
    }
    public func finishReplacement(run: Int64, agentID: String, collectorID: String, parserVersion: String) throws {
        try db.execute("BEGIN IMMEDIATE")
        do {
            let json="event_json"
            let projection=["$.id","$.timestamp","$.agentID","$.rawModelName","$.provider","$.sessionID","$.project.id"]
            var columns=projection.map{"json_extract(\(json),'\($0)')"}
            columns[1]="CAST(strftime('%s',json_extract(event_json,'$.timestamp')) AS REAL)+CAST(substr(json_extract(event_json,'$.timestamp'),21,3) AS REAL)/1000.0"
            columns += TokenMetrics.names.map{"json_extract(event_json,'$.metrics.\($0).value')"}
            columns += ["$.cost","$.currency","$.isEstimated","$.sourceEventID","$.fingerprint","$.sourcePath","$.collectorID"].map{"json_extract(event_json,'\($0)')"}
            columns += ["event_json","json_extract(event_json,'$.createdAt')"]
            columns += TokenMetrics.names.map{"json_extract(event_json,'$.metrics.\($0).state')"}
            let invalid=try db.prepare("SELECT COUNT(*) FROM usage_staging WHERE run_id=? AND json_extract(event_json,'$.agentID')!=?",[.integer(run),.text(agentID)])
            defer{sqlite3_finalize(invalid)};sqlite3_step(invalid)
            guard sqlite3_column_int(invalid,0)==0 else{throw CoreError.invalid("Replacement scope mismatch")}
            let detection=try Utilities.json(DetectionResult(installed:true,evidence:["usage_source"],sourceAvailable:true))
            try db.run("INSERT OR IGNORE INTO agents SELECT DISTINCT json_extract(event_json,'$.agentID'),json_extract(event_json,'$.agentName'),? FROM usage_staging WHERE run_id=?",[.text(detection),.integer(run)])
            try db.run("INSERT INTO superseded_usage_events SELECT *,? FROM usage_events WHERE agent_id=?",[.text(Utilities.iso()),.text(agentID)])
            try db.run("DELETE FROM usage_events WHERE agent_id=?",[.text(agentID)])
            try db.run("INSERT OR IGNORE INTO models SELECT DISTINCT json_extract(event_json,'$.rawModelName'),json_extract(event_json,'$.rawModelName') FROM usage_staging WHERE run_id=? AND json_extract(event_json,'$.rawModelName') IS NOT NULL",[.integer(run)])
            try db.run("INSERT OR IGNORE INTO projects SELECT DISTINCT json_extract(event_json,'$.project.id'),json_extract(event_json,'$.project.name'),json_extract(event_json,'$.project.path'),json_extract(event_json,'$.project.detectionMethod'),json_extract(event_json,'$.project.confidence') FROM usage_staging WHERE run_id=? AND json_extract(event_json,'$.project.id') IS NOT NULL",[.integer(run)])
            try db.run("INSERT OR IGNORE INTO sessions SELECT DISTINCT json_extract(event_json,'$.agentID')||':'||json_extract(event_json,'$.sessionID'),json_extract(event_json,'$.sessionID'),json_extract(event_json,'$.agentID') FROM usage_staging WHERE run_id=? AND json_extract(event_json,'$.sessionID') IS NOT NULL",[.integer(run)])
            try db.run("INSERT INTO usage_events SELECT "+columns.joined(separator:",")+" FROM usage_staging WHERE run_id=?",[.integer(run)])
            try db.run("INSERT INTO source_cursors SELECT path,?,cursor_json FROM cursor_staging WHERE run_id=? ON CONFLICT(path) DO UPDATE SET collector_id=excluded.collector_id,cursor_json=excluded.cursor_json",[.text(collectorID),.integer(run)])
            try db.run("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json",[.text("parser-adoption:"+agentID),.text(try Utilities.json(parserVersion))])
            try db.run("DELETE FROM usage_staging WHERE run_id=?",[.integer(run)]);try db.run("DELETE FROM cursor_staging WHERE run_id=?",[.integer(run)])
            try db.execute("COMMIT");dashboardRevision &+= 1
        } catch {try? db.execute("ROLLBACK");throw error}
    }
    private func predicate(_ f: QueryFilter) -> (String,[SQLValue]) {
        var clauses=["1=1"]; var args: [SQLValue]=[]
        if let s=f.start { clauses.append("timestamp>=?");args.append(.real(s)) }
        if let e=f.end { clauses.append("timestamp<?");args.append(.real(e)) }
        for (column,value) in [("agent_id",f.agent),("model",f.model),("project_id",f.project),("provider",f.provider),("session_id",f.session)] {
            if let value {
                // Keep ordinary filters indexable. Only the Unknown bucket includes NULL.
                clauses.append(value=="unknown" ? "(\(column) IS NULL OR \(column)=?)" : "\(column)=?")
                args.append(.text(value))
            }
        }
        return (clauses.joined(separator:" AND "),args)
    }
    private static let columns=["input_tokens","output_tokens","cached_input_tokens","cache_write_tokens","cached_output_tokens","reasoning_tokens","total_tokens"]
    public func basicUsage(agentID:String) throws -> (count:Int,total:Int64?,earliest:String?,latest:String?) {
        let p=try db.prepare("SELECT COUNT(*),SUM(total_tokens),MIN(timestamp),MAX(timestamp) FROM usage_events WHERE agent_id=?",[.text(agentID)])
        defer{sqlite3_finalize(p)};guard sqlite3_step(p)==SQLITE_ROW else{throw db.error()}
        let count=Int(sqlite3_column_int(p,0))
        return(count,sqlite3_column_type(p,1)==SQLITE_NULL ? nil:sqlite3_column_int64(p,1),count==0 ? nil:Utilities.iso(Date(timeIntervalSince1970:sqlite3_column_double(p,2))),count==0 ? nil:Utilities.iso(Date(timeIntervalSince1970:sqlite3_column_double(p,3))))
    }
    public func sessionWorkingDirectories(agentID: String) throws -> [String:String] {
        let p = try db.prepare("SELECT session_id,MAX(json_extract(event_json,'$.workingDirectory')) FROM usage_events WHERE agent_id=? AND session_id IS NOT NULL GROUP BY session_id HAVING COUNT(DISTINCT json_extract(event_json,'$.workingDirectory'))=1",[.text(agentID)])
        defer { sqlite3_finalize(p) }; var result: [String:String] = [:]
        while sqlite3_step(p)==SQLITE_ROW { if let id=db.string(p,0),let cwd=db.string(p,1) { result[id]=cwd } }
        return result
    }
    public func summary(_ filter: QueryFilter = QueryFilter()) throws -> UsageSummary {
        let (whereSQL,args)=predicate(filter)
        let expr=zip(Self.columns,TokenMetrics.names).map { column,name in "SUM(\(column)),COUNT(\(column)),SUM(CASE WHEN \(name)_state='unsupported' THEN 1 ELSE 0 END),SUM(CASE WHEN \(name)_state IN ('unknown','partial') THEN 1 ELSE 0 END)" }.joined(separator:",")
        let uncachedExpr = "CASE WHEN agent_id='deepseek-harness' AND source_event_id LIKE 'deepseek-harness:ledger:%' THEN input_tokens-cached_input_tokens-cache_write_tokens END"
        let sql="SELECT count(*),count(DISTINCT agent_id||':'||session_id),count(DISTINCT agent_id),count(DISTINCT project_id),COALESCE(sum(is_estimated),0),sum(cost),count(cost),max(currency),count(DISTINCT CASE WHEN timestamp>=\(Date().addingTimeInterval(-900).timeIntervalSince1970) THEN agent_id END),\(expr),SUM(\(uncachedExpr)),COUNT(\(uncachedExpr)) FROM usage_events WHERE \(whereSQL)"
        let p=try db.prepare(sql,args);defer { sqlite3_finalize(p) };guard sqlite3_step(p)==SQLITE_ROW else { throw db.error() }
        let events=Int(sqlite3_column_int(p,0)); var metrics: [String:MetricAggregate]=[:]
        for (i,name) in TokenMetrics.names.enumerated() {
            let valueIndex=Int32(9+i*4);let known=Int(sqlite3_column_int(p,valueIndex+1))
            let value=known>0 ? sqlite3_column_int64(p,valueIndex):nil
            let unsupported=Int(sqlite3_column_int(p,valueIndex+2)),unknown=Int(sqlite3_column_int(p,valueIndex+3))
            let absent:MetricState = events>0 && unsupported==events ? .unsupported : events>0 && unknown==events ? .unknown:.notAvailable
            let state: MetricState = known==0 ? absent : known<events || unknown>0 ? .partial:.known
            metrics[name]=MetricAggregate(value:value,state:state,knownEvents:known,totalEvents:events)
        }
        let knownCost=Int(sqlite3_column_int(p,6))
        var priced=knownCost>0 ? sqlite3_column_double(p,5):nil
        var currency=db.string(p,7)
        if knownCost>0 {
            let costs=try db.prepare("SELECT count(DISTINCT currency),sum(CASE WHEN currency IS NULL THEN 1 ELSE 0 END) FROM usage_events WHERE \(whereSQL) AND cost IS NOT NULL",args)
            sqlite3_step(costs)
            if sqlite3_column_int(costs,0) != 1 || sqlite3_column_int(costs,1)>0 {priced=nil;currency=nil}
            sqlite3_finalize(costs)
        }
        let rawIndex = Int32(9 + TokenMetrics.names.count * 4)
        let rawCount = Int(sqlite3_column_int(p, rawIndex+1))
        let rawInput: MetricAggregate? = rawCount>0 ? MetricAggregate(value:sqlite3_column_int64(p,rawIndex),state:rawCount==events ? .known : .partial,knownEvents:rawCount,totalEvents:events) : nil
        return UsageSummary(metrics:metrics,events:events,sessions:Int(sqlite3_column_int(p,1)),agents:Int(sqlite3_column_int(p,2)),projects:Int(sqlite3_column_int(p,3)),
                            activeAgents:Int(sqlite3_column_int(p,8)),estimatedEvents:Int(sqlite3_column_int(p,4)),cost:priced,
                            costKnownEvents:priced==nil ? 0:knownCost,currency:currency,uncachedInput:rawInput)
    }
    public func events(_ filter: QueryFilter = QueryFilter(), limit: Int = 100, offset: Int = 0, id: String? = nil) throws -> EventPage {
        var (whereSQL,args)=predicate(filter)
        if let id { whereSQL += " AND id=?";args.append(.text(id)) }
        let count=try db.prepare("SELECT count(*) FROM usage_events WHERE \(whereSQL)",args);sqlite3_step(count);let total=Int(sqlite3_column_int(count,0));sqlite3_finalize(count)
        let limit=min(max(limit,1),200);let offset=max(offset,0)
        let p=try db.prepare("SELECT event_json FROM usage_events WHERE \(whereSQL) ORDER BY timestamp DESC,id LIMIT ? OFFSET ?",args+[.integer(Int64(limit)),.integer(Int64(offset))]);defer { sqlite3_finalize(p) }
        var items:[UsageEvent]=[]
        while sqlite3_step(p)==SQLITE_ROW { if let s=db.string(p,0) { items.append(try JSONDecoder().decode(UsageEvent.self,from:Data(s.utf8))) } }
        return EventPage(events:items,total:total,offset:offset,limit:limit)
    }
    private func distinct(_ column: String, filter: QueryFilter) throws -> [String] {
        let (whereSQL,args)=predicate(filter)
        let p=try db.prepare("SELECT DISTINCT \(column) FROM usage_events WHERE \(whereSQL) AND \(column) IS NOT NULL ORDER BY \(column)",args);defer { sqlite3_finalize(p) }
        var values:[String]=[];while sqlite3_step(p)==SQLITE_ROW { if let s=db.string(p,0) { values.append(s) } };return values
    }
    private func lastSeen(_ f: QueryFilter) throws -> String? {
        let (whereSQL,args)=predicate(f);let p=try db.prepare("SELECT timestamp FROM usage_events WHERE \(whereSQL) ORDER BY timestamp DESC LIMIT 1",args);defer { sqlite3_finalize(p) }
        guard sqlite3_step(p)==SQLITE_ROW else{return nil}
        return Utilities.iso(Date(timeIntervalSince1970:sqlite3_column_double(p,0)))
    }
    public func groups(_ dimension: String, filter: QueryFilter) throws -> [GroupRow] {
        let column: String
        switch dimension { case "agents":column="agent_id";case "models":column="model";case "projects":column="project_id";case "sessions":column="session_id";default:throw CoreError.invalid("Unknown group dimension") }
        let (whereSQL,args)=predicate(filter)
        let p=try db.prepare("SELECT COALESCE(\(column),'unknown'),SUM(total_tokens) FROM usage_events WHERE \(whereSQL) GROUP BY \(column) ORDER BY SUM(total_tokens) DESC",args);defer { sqlite3_finalize(p) }
        var ids:[String]=[];while sqlite3_step(p)==SQLITE_ROW { if let s=db.string(p,0) { ids.append(s) } }
        var result:[GroupRow]=[]
        for id in ids {
            var f=filter;var name=id;var path:String?
            switch dimension {
            case "agents": f.agent=id; let q=try db.prepare("SELECT name FROM agents WHERE id=?",[.text(id)]);sqlite3_step(q);name=db.string(q,0) ?? id;sqlite3_finalize(q)
            case "models": f.model=id
            case "projects": f.project=id;let q=try db.prepare("SELECT name,path FROM projects WHERE id=?",[.text(id)]);sqlite3_step(q);name=db.string(q,0) ?? "Unknown project";path=db.string(q,1);sqlite3_finalize(q)
            default:f.session=id
            }
            result.append(GroupRow(id:id,name:name,path:path,lastActivity:try lastSeen(f),models:try distinct("model",filter:f),agentIDs:try distinct("agent_id",filter:f),projectIDs:try distinct("project_id",filter:f),summary:try summary(f)))
        }
        return result
    }
    public func collectors() throws -> [CollectorRecord] {
        let settings=try self.setting("app",as:AppSettings.self) ?? AppSettings()
        let p=try db.prepare("SELECT descriptor_json,health_json,detection_json FROM collectors JOIN agents ON collectors.agent_id=agents.id ORDER BY agents.name");defer { sqlite3_finalize(p) }
        var rows:[CollectorRecord]=[]
        while sqlite3_step(p)==SQLITE_ROW {
            let d=try JSONDecoder().decode(CollectorDescriptor.self,from:Data(db.string(p,0)!.utf8))
            let configured = !d.id.hasPrefix("custom-") || settings.customAgents.contains{"custom-"+$0.id==d.id && $0.discoveryOnly != true}
            var record=CollectorRecord(descriptor:d,detection:try JSONDecoder().decode(DetectionResult.self,from:Data(db.string(p,2)!.utf8)),health:try JSONDecoder().decode(CollectorHealth.self,from:Data(db.string(p,1)!.utf8)),enabled: configured && !settings.disabledCollectors.contains(d.id))
            let stats=try basicUsage(agentID:d.agentID)
            record.coverage=SourceCoverage.make(descriptor:d,health:record.health,earliest:stats.earliest,latest:stats.latest,records:stats.count)
            if d.agentID=="workbuddy" {record.coverage?.traceEvidence=try setting("workbuddy-trace-evidence",as:WorkBuddyTraceEvidence.self)}
            rows.append(record)
        };return rows
    }
    public func agents(_ filter: QueryFilter = QueryFilter()) throws -> [AgentRecord] {
        let custom=try (setting("app",as:AppSettings.self) ?? AppSettings()).customAgents
        let cs=try collectors();let p=try db.prepare("SELECT id,name,detection_json FROM agents ORDER BY name");defer { sqlite3_finalize(p) }
        var rows:[AgentRecord]=[]
        while sqlite3_step(p)==SQLITE_ROW {
            let id=db.string(p,0)!;if let a=filter.agent,a != id { continue }
            var f=filter;f.agent=id
            var all=f;all.start=nil;all.end=nil
            var today=all;let calendar=self.calendar(filter.timeZone);today.start=calendar.startOfDay(for:Date()).timeIntervalSince1970;today.end=calendar.date(byAdding:.day,value:1,to:Date(timeIntervalSince1970:today.start!))!.timeIntervalSince1970
            let detection=try JSONDecoder().decode(DetectionResult.self,from:Data(db.string(p,2)!.utf8))
            let collector=custom.contains(where:{"custom-"+$0.id==id && $0.discoveryOnly==true}) ? nil:cs.first{$0.descriptor.agentID==id}
            var allSummary=try summary(all)
            var selectedSummary=f.start==nil && f.end==nil ? allSummary:try summary(f)
            var todaySummary=try summary(today)
            guard detection.installed || !detection.evidence.isEmpty || allSummary.events>0 || custom.contains(where:{"custom-"+$0.id==id}) else{continue}
            if collector==nil && allSummary.events==0 {
                for key in TokenMetrics.names {
                    selectedSummary.metrics[key]?.state = .unsupported;todaySummary.metrics[key]?.state = .unsupported;allSummary.metrics[key]?.state = .unsupported
                }
            }
            rows.append(AgentRecord(id:id,name:db.string(p,1)!,detection:detection,collector:collector,summary:selectedSummary,today:todaySummary,allTime:allSummary,lastSeen:try lastSeen(all),models:try distinct("model",filter:f),projects:try distinct("project_id",filter:f)))
        };return rows
    }
    public func agentIdentities() throws -> [AgentIdentity] {
        let p=try db.prepare("SELECT id,name,detection_json FROM agents ORDER BY name");defer{sqlite3_finalize(p)}
        var identities:[AgentIdentity]=[]
        while sqlite3_step(p)==SQLITE_ROW {
            identities.append(AgentIdentity(id:db.string(p,0)!,name:db.string(p,1)!,detection:try JSONDecoder().decode(DetectionResult.self,from:Data(db.string(p,2)!.utf8))))
        };return identities
    }
    public func filterOptions() throws -> FilterOptions {
        let p=try db.prepare("SELECT id,name FROM agents ORDER BY name");defer { sqlite3_finalize(p) };var agents:[FilterOptions.Option]=[]
        while sqlite3_step(p)==SQLITE_ROW { agents.append(.init(id:db.string(p,0)!,name:db.string(p,1)!)) }
        let q=try db.prepare("SELECT id,name FROM projects ORDER BY name");defer { sqlite3_finalize(q) };var projects:[FilterOptions.Option]=[]
        while sqlite3_step(q)==SQLITE_ROW { projects.append(.init(id:db.string(q,0)!,name:db.string(q,1)!)) }
        return FilterOptions(agents:agents,models:try distinct("model",filter:QueryFilter()).map{.init(id:$0,name:$0)},projects:projects,providers:try distinct("provider",filter:QueryFilter()).map{.init(id:$0,name:$0)})
    }
    private func calendar(_ zone: String) -> Calendar { var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:zone) ?? .current;return c }
    public func menuSnapshot(timeZone:String=TimeZone.current.identifier) throws -> MenuSnapshot {
        let c=calendar(timeZone);let start=c.startOfDay(for:Date());let end=c.date(byAdding:.day,value:1,to:start)!
        let f=QueryFilter(start:start.timeIntervalSince1970,end:end.timeIntervalSince1970,timeZone:timeZone)
        let today=try summary(f);let yesterday=try summary(QueryFilter(start:c.date(byAdding:.day,value:-1,to:start)!.timeIntervalSince1970,end:start.timeIntervalSince1970,timeZone:timeZone))
        let change=today.metrics["total"]?.value.flatMap{a in yesterday.metrics["total"]?.value.flatMap{b in b>0 ? (Double(a)-Double(b))/Double(b)*100:nil}}
        return MenuSnapshot(today:today,yesterday:yesterday,agents:try groups("agents",filter:f),models:try groups("models",filter:f),changePercent:change)
    }
    public func overview(_ filter: QueryFilter = QueryFilter()) throws -> OverviewResponse {
        let c=calendar(filter.timeZone);let start=c.startOfDay(for:Date());let end=c.date(byAdding:.day,value:1,to:start)!
        var f=filter;f.start=start.timeIntervalSince1970;f.end=end.timeIntervalSince1970;let today=try summary(f)
        f.start=c.date(byAdding:.day,value:-6,to:start)!.timeIntervalSince1970;let seven=try summary(f)
        f.start=c.date(byAdding:.day,value:-29,to:start)!.timeIntervalSince1970;let thirty=try summary(f)
        f.start=nil;f.end=nil;let all=try summary(f)
        f.start=c.date(byAdding:.day,value:-1,to:start)!.timeIntervalSince1970;f.end=start.timeIntervalSince1970;let yesterday=try summary(f)
        let change=today.metrics["total"]?.value.flatMap { a in yesterday.metrics["total"]?.value.flatMap { b in b>0 ? (Double(a)-Double(b))/Double(b)*100:nil } }
        return OverviewResponse(selected:try summary(filter),today:today,sevenDays:seven,thirtyDays:thirty,allTime:all,yesterday:yesterday,changePercent:change,
                                timeline:try timeline(filter),agentDistribution:try groups("agents",filter:filter),modelDistribution:try groups("models",filter:filter),timeZone:c.timeZone.identifier)
    }
    public func timeline(_ filter: QueryFilter) throws -> [TimelinePoint] {
        let c=calendar(filter.timeZone);let (whereSQL,args)=predicate(filter)
        let p=try db.prepare("SELECT min(timestamp),max(timestamp) FROM usage_events WHERE \(whereSQL)",args);sqlite3_step(p)
        let earliest=sqlite3_column_type(p,0)==SQLITE_NULL ? Date():Date(timeIntervalSince1970:sqlite3_column_double(p,0))
        let latest=sqlite3_column_type(p,1)==SQLITE_NULL ? Date():Date(timeIntervalSince1970:sqlite3_column_double(p,1));sqlite3_finalize(p)
        let start=filter.start.map{Date(timeIntervalSince1970:$0)} ?? c.startOfDay(for:earliest)
        let end=filter.end.map{Date(timeIntervalSince1970:$0)} ?? c.date(byAdding:.day,value:1,to:c.startOfDay(for:latest))!
        let days=end.timeIntervalSince(start)/86400
        let component:Calendar.Component = days<=2 ? .hour : days<=62 ? .day : days<=3660 ? .month:.year
        let estimatedBuckets=days<=2 ? days*24 : days<=62 ? days : days<=3660 ? days/28:days/365
        let step=max(1,Int(ceil(estimatedBuckets/240)))
        var points:[TimelinePoint]=[];var date=start
        while date<end && points.count<500 {
            let next=min(c.date(byAdding:component,value:step,to:date)!,end);var f=filter;f.start=date.timeIntervalSince1970;f.end=next.timeIntervalSince1970
            points.append(TimelinePoint(timestamp:Utilities.iso(date),end:Utilities.iso(next),summary:try summary(f)));date=next
        };return points
    }
}
