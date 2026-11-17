CREATE TABLE speech_blocks (
    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    cache_key TEXT NOT NULL,
    result_json TEXT NOT NULL,
    duration_ms INTEGER NOT NULL CHECK(duration_ms > 0),
    elapsed_ms INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY (meeting_id, cache_key)
);

ALTER TABLE live_chunks ADD COLUMN last_sequence INTEGER;

CREATE TABLE speaker_blocks (
    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    cache_key TEXT NOT NULL,
    result_json TEXT NOT NULL,
    PRIMARY KEY (meeting_id, cache_key)
);

ALTER TABLE live_sessions ADD COLUMN speaker_turns_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE live_sessions ADD COLUMN speaker_profiles_json TEXT;
