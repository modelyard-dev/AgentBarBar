CREATE INDEX usage_provider ON usage_events(provider,timestamp);
CREATE INDEX cursor_collector ON source_cursors(collector_id);
CREATE INDEX run_collector ON collection_runs(collector_id,id);
INSERT INTO schema_migrations VALUES(2,datetime('now'));
PRAGMA user_version=2;
