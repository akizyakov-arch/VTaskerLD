CREATE TABLE company_terms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    revision INTEGER NOT NULL DEFAULT 1,
    data_json TEXT NOT NULL CHECK (json_valid(data_json))
);
