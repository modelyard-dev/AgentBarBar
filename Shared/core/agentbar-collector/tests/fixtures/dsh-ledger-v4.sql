-- Anonymous metadata only. Mirrors the verified DSH storage/accounting schemas.
CREATE TABLE usage_records(canonical_id TEXT PRIMARY KEY,session_id TEXT,timestamp INTEGER,provider TEXT,model TEXT,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,total_tokens INTEGER,unclassified INTEGER,source_type TEXT,historical_or_live TEXT,updated_at INTEGER,schema_version INTEGER,accounting_version INTEGER,excluded_reason TEXT);
CREATE TABLE meta(id INTEGER PRIMARY KEY,storage_schema_version INTEGER,record_generation INTEGER,aggregate_generation INTEGER,migration_status TEXT);
CREATE TABLE aggregate_global(id INTEGER PRIMARY KEY,calls INTEGER,total_tokens INTEGER);
INSERT INTO meta VALUES(1,4,2,2,'done');
INSERT INTO aggregate_global VALUES(1,2,410);
INSERT INTO usage_records VALUES('anonymous-session:1:1','anonymous-session',1791043200000,'anonymous-provider','raw-model',50,10,100,0,3,160,0,'legacy_store','historical',1000,2,1,NULL);
INSERT INTO usage_records VALUES('anonymous-session:1:2','anonymous-session',1791043201000,'anonymous-provider','raw-model',20,30,200,0,5,250,0,'live_event','live',2000,4,2,NULL);
