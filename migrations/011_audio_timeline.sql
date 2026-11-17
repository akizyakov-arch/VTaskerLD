-- One durable occurrence per captured fragment; imports remain idempotent.
CREATE TABLE audio_timeline (
    id INTEGER PRIMARY KEY,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    session_id TEXT,
    sequence INTEGER,
    kind TEXT NOT NULL CHECK(kind IN ('capture','import','recovered')),
    CHECK((session_id IS NULL AND sequence IS NULL) OR (session_id IS NOT NULL AND sequence IS NOT NULL)),
    UNIQUE(session_id,sequence)
);
CREATE UNIQUE INDEX timeline_import ON audio_timeline(recording_id) WHERE session_id IS NULL;
CREATE INDEX timeline_meeting ON audio_timeline(meeting_id,id);
-- Preserve the exact playback/STT order used by previous versions.
INSERT INTO audio_timeline(meeting_id,recording_id,session_id,sequence,kind)
SELECT meeting_id,recording_id,session_id,sequence,'capture' FROM capture_fragments ORDER BY meeting_id,session_id,sequence;
INSERT INTO audio_timeline(meeting_id,recording_id,kind)
SELECT meeting_id,id,'import' FROM recordings r WHERE NOT EXISTS (SELECT 1 FROM capture_fragments f WHERE f.recording_id=r.id) ORDER BY meeting_id,id;
