CREATE TABLE meeting_terminology (
    meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
    industries_json TEXT NOT NULL CHECK (json_valid(industries_json))
);
