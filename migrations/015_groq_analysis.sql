CREATE TABLE meeting_analyses (
 id INTEGER PRIMARY KEY,
 meeting_id INTEGER NOT NULL REFERENCES meetings(id),
 model_run_id INTEGER NOT NULL REFERENCES model_runs(id),
 source_revision TEXT NOT NULL,
 model TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','running','completed','failed','interrupted')),
 input_json TEXT NOT NULL,
 result_json TEXT,
 error TEXT,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 finished_at TEXT,
 UNIQUE(meeting_id,source_revision,model)
);
CREATE INDEX analyses_by_meeting ON meeting_analyses(meeting_id,id);
