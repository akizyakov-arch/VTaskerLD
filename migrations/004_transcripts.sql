CREATE TABLE model_runs (
    id INTEGER PRIMARY KEY,
    job_id INTEGER NOT NULL REFERENCES processing_jobs(id),
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    model_path TEXT NOT NULL,
    model_sha256 TEXT NOT NULL,
    engine_path TEXT NOT NULL,
    engine_sha256 TEXT NOT NULL,
    language TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('running','completed','failed')),
    inputs_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE segments (
    id INTEGER PRIMARY KEY,
    model_run_id INTEGER NOT NULL REFERENCES model_runs(id),
    start_ms INTEGER NOT NULL CHECK(start_ms>=0),
    end_ms INTEGER NOT NULL CHECK(end_ms>=start_ms),
    text TEXT NOT NULL,
    sources_json TEXT NOT NULL
);
CREATE INDEX segments_by_run ON segments(model_run_id,start_ms,id);
