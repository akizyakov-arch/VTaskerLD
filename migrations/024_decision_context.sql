CREATE TABLE IF NOT EXISTS decision_context (
    decision_id INTEGER PRIMARY KEY REFERENCES decisions(id) ON DELETE CASCADE,
    approved_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    reviewer_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'approved' CHECK(status IN ('approved','superseded','cancelled')),
    reason TEXT,
    supersedes_id INTEGER REFERENCES decisions(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS decision_tasks (
    decision_id INTEGER NOT NULL REFERENCES decisions(id) ON DELETE CASCADE,
    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    PRIMARY KEY(decision_id,task_id)
);

INSERT OR IGNORE INTO decision_tasks(decision_id,task_id)
SELECT d.id,t.id FROM decisions d JOIN tasks t
  ON t.id=json_extract(d.source_json,'$.task_id') AND t.is_demo=d.is_demo
WHERE json_extract(t.data_json,'$.project_id') IS d.project_id;
