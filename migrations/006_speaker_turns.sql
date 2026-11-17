CREATE TABLE speaker_turns (
    id INTEGER PRIMARY KEY,
    model_run_id INTEGER NOT NULL REFERENCES model_runs(id),
    start_ms INTEGER NOT NULL CHECK(start_ms>=0),
    end_ms INTEGER NOT NULL CHECK(end_ms>start_ms),
    speaker_id TEXT NOT NULL
);
CREATE INDEX turns_by_run ON speaker_turns(model_run_id,start_ms,id);
