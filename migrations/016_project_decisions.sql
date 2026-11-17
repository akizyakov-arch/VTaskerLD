ALTER TABLE decisions RENAME TO decisions_with_required_meeting;
CREATE TABLE decisions (
    id INTEGER PRIMARY KEY,
    project_id INTEGER REFERENCES projects(id),
    meeting_id INTEGER REFERENCES meetings(id),
    text TEXT NOT NULL,
    source_json TEXT NOT NULL,
    is_demo INTEGER NOT NULL DEFAULT 0,
    CHECK (project_id IS NOT NULL OR meeting_id IS NOT NULL)
);
INSERT INTO decisions (id, project_id, meeting_id, text, source_json, is_demo)
SELECT id, project_id, meeting_id, text, source_json, is_demo FROM decisions_with_required_meeting;
DROP TABLE decisions_with_required_meeting;
