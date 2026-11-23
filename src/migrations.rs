//! Ordered, transactional upgrades for every supported database version.
use anyhow::{bail, Result};
use rusqlite::Transaction;

const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/001_initial.sql"),
    include_str!("../migrations/002_recordings.sql"),
    include_str!("../migrations/003_capture_fragments.sql"),
    include_str!("../migrations/004_transcripts.sql"),
    include_str!("../migrations/005_speech_parameters.sql"),
    include_str!("../migrations/006_speaker_turns.sql"),
    include_str!("../migrations/007_speaker_assignments.sql"),
    include_str!("../migrations/008_workspace.sql"),
    include_str!("../migrations/009_capture_sources.sql"),
    include_str!("../migrations/010_live.sql"),
    include_str!("../migrations/011_audio_timeline.sql"),
    include_str!("../migrations/012_voice_profiles.sql"),
    include_str!("../migrations/013_voice_matching.sql"),
    include_str!("../migrations/014_meeting_notes.sql"),
    include_str!("../migrations/015_groq_analysis.sql"),
    include_str!("../migrations/016_project_decisions.sql"),
    include_str!("../migrations/017_meeting_schedule.sql"),
    include_str!("../migrations/018_person_profiles.sql"),
    include_str!("../migrations/019_person_names.sql"),
    include_str!("../migrations/020_person_directory.sql"),
    include_str!("../migrations/021_speech_blocks.sql"),
    include_str!("../migrations/022_processing_timeline.sql"),
    include_str!("../migrations/023_ai_usage.sql"),
    include_str!("../migrations/024_decision_context.sql"),
    include_str!("../migrations/025_task_links_and_notifications.sql"),
    include_str!("../migrations/026_live_voice_hints.sql"),
    include_str!("../migrations/027_company_glossary.sql"),
    include_str!("../migrations/028_term_reviews.sql"),
    include_str!("../migrations/029_meeting_terminology.sql"),
];

pub(crate) fn apply(tx: &Transaction<'_>, version: i64) -> Result<()> {
    let supported = MIGRATIONS.len() as i64;
    if version > supported {
        bail!("database version {version} is newer than supported version {supported}");
    }
    if version < 0 {
        bail!("invalid database version {version}");
    }
    for (index, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", index as i64 + 1)?;
    }
    Ok(())
}
