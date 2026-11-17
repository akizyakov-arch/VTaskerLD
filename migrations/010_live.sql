CREATE TABLE live_sessions (
    session_id TEXT PRIMARY KEY,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    state TEXT NOT NULL CHECK(state IN ('active','finished','deferred','interrupted')),
    reason TEXT,
    model_path TEXT NOT NULL,
    language TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX live_sessions_meeting ON live_sessions(meeting_id,created_at);
CREATE TABLE live_chunks (
    id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES live_sessions(session_id),
    sequence INTEGER NOT NULL,
    recording_id INTEGER NOT NULL REFERENCES recordings(id),
    start_ms INTEGER NOT NULL,
    end_ms INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','running','completed','deferred','failed')),
    result_json TEXT NOT NULL DEFAULT '[]',
    model_sha256 TEXT,
    engine_sha256 TEXT,
    elapsed_ms INTEGER,
    error TEXT,
    UNIQUE(session_id,sequence)
);
CREATE INDEX live_chunks_queue ON live_chunks(state,id);
