ALTER TABLE voice_jobs ADD COLUMN source_json TEXT;
ALTER TABLE voice_consents ADD COLUMN source_json TEXT;
CREATE TABLE voice_match_jobs (
 id INTEGER PRIMARY KEY,
 model_run_id INTEGER NOT NULL REFERENCES model_runs(id),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','running','completed','failed')),
 threshold REAL NOT NULL CHECK(threshold>=0.5 AND threshold<=0.99),
 margin REAL NOT NULL CHECK(margin>=0.05 AND margin<=0.5),
 error TEXT,
 model_sha256 TEXT,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX one_voice_matching ON voice_match_jobs(model_run_id) WHERE state IN ('pending','running');
CREATE TABLE voice_matches (
 id INTEGER PRIMARY KEY,
 job_id INTEGER NOT NULL REFERENCES voice_match_jobs(id),
 speaker_id TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('candidate','unknown')),
 person_id INTEGER REFERENCES people(id),
 profile_id INTEGER REFERENCES voice_profiles(id) ON DELETE SET NULL,
 similarity REAL,
 reason TEXT NOT NULL,
 source_json TEXT NOT NULL,
 UNIQUE(job_id,speaker_id)
);
