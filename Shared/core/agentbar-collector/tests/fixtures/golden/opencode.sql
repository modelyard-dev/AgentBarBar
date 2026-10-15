-- Anonymous metadata only; source message bodies/parts are never selected by the collector.
CREATE TABLE session(id TEXT PRIMARY KEY,directory TEXT NOT NULL,parent_id TEXT,time_created INTEGER NOT NULL);
CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,time_created INTEGER NOT NULL,time_updated INTEGER NOT NULL,data TEXT NOT NULL);
INSERT INTO session VALUES('anonymous-open-session','/anonymous/ProjectO',NULL,1791061000000);
INSERT INTO session VALUES('anonymous-open-fork','/anonymous/ProjectO','anonymous-open-session',1791061400000);
INSERT INTO message VALUES('open-request-1','anonymous-open-session',1791061200000,1791061202000,'{"role":"assistant","time":{"created":1791061200000,"completed":1791061202000},"modelID":"provider/raw-model-1","providerID":"open-provider","tokens":{"total":1220,"input":1000,"output":80,"reasoning":20,"cache":{"read":100,"write":20}},"cost":0,"path":{"cwd":"/anonymous/ProjectO"}}');
INSERT INTO message VALUES('open-inflight','anonymous-open-session',1791061300000,1791061300000,'{"role":"assistant","time":{"created":1791061300000},"modelID":"provider/raw-model-1","providerID":"open-provider","tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
INSERT INTO message VALUES('open-fork-copy','anonymous-open-fork',1791061200000,1791061400000,'{"role":"assistant","time":{"created":1791061200000,"completed":1791061202000},"modelID":"provider/raw-model-1","providerID":"open-provider","tokens":{"total":1220,"input":1000,"output":80,"reasoning":20,"cache":{"read":100,"write":20}}}');
