CREATE TABLE superseded_usage_events AS SELECT *, '' AS superseded_at FROM usage_events WHERE 0;
DROP INDEX usage_aggregation;
CREATE INDEX usage_aggregation ON usage_events(
  agent_id,timestamp,model,provider,project_id,session_id,
  input_tokens,output_tokens,cached_input_tokens,cache_write_tokens,cached_output_tokens,
  reasoning_tokens,total_tokens,cost,currency,is_estimated,
  input_state,output_state,cacheRead_state,cacheWrite_state,cachedOutput_state,reasoning_state,total_state,source_event_id);
INSERT INTO schema_migrations VALUES(6,datetime('now'));
PRAGMA user_version=6;
