CREATE INDEX usage_aggregation ON usage_events(
  agent_id,timestamp,model,provider,project_id,session_id,
  input_tokens,output_tokens,cached_input_tokens,cache_write_tokens,cached_output_tokens,
  reasoning_tokens,total_tokens,cost,currency,is_estimated,
  input_state,output_state,cacheRead_state,cacheWrite_state,cachedOutput_state,reasoning_state,total_state);
INSERT INTO schema_migrations VALUES(5,datetime('now'));
PRAGMA user_version=5;
