UPDATE usage_events SET timestamp=CAST(strftime('%s',json_extract(event_json,'$.timestamp')) AS REAL)
  + CAST(substr(json_extract(event_json,'$.timestamp'),21,3) AS REAL)/1000.0;
INSERT INTO schema_migrations VALUES(4,datetime('now'));
PRAGMA user_version=4;
