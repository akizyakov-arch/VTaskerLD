CREATE TABLE IF NOT EXISTS person_profiles (
    person_id INTEGER PRIMARY KEY REFERENCES people(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT '',
    organization TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT ''
);
