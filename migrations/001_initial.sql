CREATE TABLE people (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL CHECK(length(trim(name)) > 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE meetings (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
    status TEXT NOT NULL DEFAULT 'created' CHECK(status IN ('created','recording','completed','failed')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE processing_jobs (
    id INTEGER PRIMARY KEY,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    kind TEXT NOT NULL CHECK(kind IN ('transcribe')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','completed','failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX one_active_job ON processing_jobs(meeting_id,kind) WHERE status IN ('pending','running');
