CREATE TABLE capture_sources (
    session_id TEXT PRIMARY KEY,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    device_uid TEXT NOT NULL,
    device_name TEXT NOT NULL,
    source_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX capture_sources_meeting ON capture_sources(meeting_id);
