CREATE TABLE IF NOT EXISTS ai_usage (
    id INTEGER PRIMARY KEY,
    day TEXT NOT NULL,
    model TEXT NOT NULL,
    stage TEXT NOT NULL,
    phase TEXT NOT NULL,
    input_tokens INTEGER,
    output_tokens INTEGER,
    charged_tokens INTEGER NOT NULL CHECK(charged_tokens >= 0),
    state TEXT NOT NULL CHECK(state IN ('reserved','reported','estimated','rejected'))
);
CREATE INDEX IF NOT EXISTS ai_usage_by_day ON ai_usage(day);

CREATE TABLE IF NOT EXISTS ai_extraction_cache (
    key TEXT PRIMARY KEY,
    result_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
