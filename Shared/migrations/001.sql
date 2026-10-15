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
