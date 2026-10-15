CREATE TABLE usage_staging(run_id INTEGER,source_event_id TEXT,event_json TEXT NOT NULL,PRIMARY KEY(run_id,source_event_id));
CREATE TABLE cursor_staging(run_id INTEGER,path TEXT,cursor_json TEXT NOT NULL,PRIMARY KEY(run_id,path));
INSERT INTO schema_migrations VALUES(7,datetime('now')); PRAGMA user_version=7;
