CREATE TABLE task_links (
    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    related_task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    source_json TEXT NOT NULL,
    PRIMARY KEY(task_id,related_task_id),
    CHECK(task_id <> related_task_id)
);
CREATE INDEX task_links_by_related ON task_links(related_task_id);

CREATE TABLE task_notifications (
    id INTEGER PRIMARY KEY,
    event_key TEXT NOT NULL,
    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    recipient_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    proposal_id INTEGER NOT NULL REFERENCES proposals(id) ON DELETE CASCADE,
    decision_id INTEGER REFERENCES decisions(id) ON DELETE SET NULL,
    payload_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    read_at TEXT,
    UNIQUE(event_key,task_id,recipient_id)
);
CREATE INDEX task_notifications_by_recipient ON task_notifications(recipient_id,id);
