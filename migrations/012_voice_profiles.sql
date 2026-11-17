CREATE TABLE voice_consents (
 id INTEGER PRIMARY KEY,
 person_id INTEGER NOT NULL REFERENCES people(id),
 text_version TEXT NOT NULL DEFAULT 'local-voice-v1',
 granted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 revoked_at TEXT
);
CREATE TABLE voice_jobs (
 id INTEGER PRIMARY KEY,
 person_id INTEGER NOT NULL REFERENCES people(id),
 consent_id INTEGER NOT NULL REFERENCES voice_consents(id),
 input_path TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','running','completed','failed')),
 error TEXT,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX one_voice_job ON voice_jobs(person_id) WHERE state IN ('pending','running');
CREATE TABLE voice_samples (
 id INTEGER PRIMARY KEY,
 person_id INTEGER NOT NULL REFERENCES people(id),
 consent_id INTEGER NOT NULL REFERENCES voice_consents(id),
 job_id INTEGER NOT NULL UNIQUE REFERENCES voice_jobs(id),
 path TEXT NOT NULL UNIQUE,
 sha256 TEXT NOT NULL,
 model_sha256 TEXT NOT NULL,
 engine_sha256 TEXT NOT NULL,
 embedding_json TEXT NOT NULL,
 quality_json TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE voice_profiles (
 id INTEGER PRIMARY KEY,
 person_id INTEGER NOT NULL REFERENCES people(id),
 model_sha256 TEXT NOT NULL,
 revision INTEGER NOT NULL,
 sample_count INTEGER NOT NULL,
 embedding_json TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 UNIQUE(person_id,model_sha256,revision)
);
