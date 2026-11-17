-- Content-addressed WAV blobs may repeat (e.g. silence). Preserve each occurrence.
CREATE TABLE capture_fragments (
    meeting_id INTEGER NOT NULL REFERENCES meetings(id),
    session_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK(sequence >= 0),
    recording_id INTEGER NOT NULL REFERENCES recordings(id),
    start_frame INTEGER NOT NULL CHECK(start_frame >= 0),
    PRIMARY KEY(session_id, sequence)
);
CREATE INDEX fragments_by_meeting ON capture_fragments(meeting_id,session_id,sequence);
