CREATE TABLE meeting_notes (
    meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id),
    data_json TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK(revision > 0),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
