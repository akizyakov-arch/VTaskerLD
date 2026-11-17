CREATE TABLE recordings (
    id INTEGER PRIMARY KEY,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    path TEXT NOT NULL UNIQUE,
    sha256 TEXT NOT NULL CHECK(length(sha256)=64),
    sample_rate INTEGER NOT NULL CHECK(sample_rate > 0),
    channels INTEGER NOT NULL CHECK(channels > 0),
    frames INTEGER NOT NULL CHECK(frames > 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE(meeting_id, sha256)
);
