CREATE TABLE live_voice_hints (
    occurrence_id INTEGER PRIMARY KEY REFERENCES audio_timeline(id) ON DELETE CASCADE,
    meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    profile_id INTEGER NOT NULL REFERENCES voice_profiles(id) ON DELETE CASCADE,
    person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    start_ms INTEGER NOT NULL CHECK(start_ms >= 0),
    end_ms INTEGER NOT NULL CHECK(end_ms > start_ms),
    similarity REAL NOT NULL
);
CREATE INDEX live_voice_hints_by_meeting ON live_voice_hints(meeting_id,start_ms);
