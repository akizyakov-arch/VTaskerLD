CREATE TABLE term_reviews (
    spelling TEXT PRIMARY KEY,
    status TEXT NOT NULL CHECK (status IN ('approved', 'merged', 'rejected')),
    term_id INTEGER REFERENCES company_terms(id) ON DELETE SET NULL,
    reviewed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX meeting_analyses_term_findings
ON meeting_analyses(id DESC)
WHERE state='completed' AND instr(result_json, '"unclear_term"') > 0;
