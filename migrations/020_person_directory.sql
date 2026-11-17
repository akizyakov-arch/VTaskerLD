ALTER TABLE person_profiles ADD COLUMN department TEXT NOT NULL DEFAULT '';
ALTER TABLE person_profiles ADD COLUMN nickname TEXT NOT NULL DEFAULT '';
ALTER TABLE person_profiles ADD COLUMN photo BLOB;
ALTER TABLE person_profiles ADD COLUMN photo_revision INTEGER NOT NULL DEFAULT 0;
