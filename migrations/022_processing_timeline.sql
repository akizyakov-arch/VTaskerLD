ALTER TABLE processing_jobs ADD COLUMN stage TEXT;
ALTER TABLE processing_jobs ADD COLUMN started_at INTEGER;
ALTER TABLE processing_jobs ADD COLUMN finished_at INTEGER;
