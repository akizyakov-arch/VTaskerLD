-- Append-only manual corrections, deliberately scoped to one model run.
CREATE TABLE speaker_assignments (
    id INTEGER PRIMARY KEY,
    model_run_id INTEGER NOT NULL REFERENCES model_runs(id),
    speaker_id TEXT NOT NULL,
    person_id INTEGER REFERENCES people(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX assignments_by_speaker ON speaker_assignments(model_run_id,speaker_id,id);
