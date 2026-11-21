pub mod audio;
pub mod capture;
pub mod diarization;
pub mod groq;
pub mod live;
pub mod live_voice;
mod local_analysis;
pub mod meeting_notes;
mod migrations;
pub mod people;
pub mod speech;
pub mod voice;
pub mod voice_capture;
pub mod voice_matching;
pub mod web;
pub mod workspace;
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::Path;

pub struct Store(Connection);
impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        let mut conn = Connection::open(path).context("cannot open database")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        let tx = conn.transaction()?;
        let version: i64 = tx.pragma_query_value(None, "user_version", |r| r.get(0))?;
        migrations::apply(&tx, version)?;
        tx.commit()?;
        Ok(Self(conn))
    }
    pub fn add_person(&self, name: &str) -> Result<i64> {
        validate_text(name)?;
        self.0
            .execute("INSERT INTO people(name) VALUES (?1)", [name.trim()])?;
        Ok(self.0.last_insert_rowid())
    }
    pub fn create_meeting(&self, title: &str) -> Result<i64> {
        validate_text(title)?;
        self.0
            .execute("INSERT INTO meetings(title) VALUES (?1)", [title.trim()])?;
        Ok(self.0.last_insert_rowid())
    }
    pub fn people(&self) -> Result<Value> {
        let mut stmt = self.0.prepare(
            "SELECT p.id,p.name,p.created_at,f.role,f.organization,f.email,f.phone,f.notes,f.last_name,f.patronymic,
                    f.department,f.nickname,CASE WHEN f.photo IS NOT NULL THEN f.photo_revision END
             FROM people p LEFT JOIN person_profiles f ON f.person_id=p.id ORDER BY p.id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(json!({
                "id":r.get::<_,i64>(0)?, "name":r.get::<_,String>(1)?, "created_at":r.get::<_,String>(2)?,
                "role":r.get::<_,Option<String>>(3)?, "organization":r.get::<_,Option<String>>(4)?,
                "email":r.get::<_,Option<String>>(5)?, "phone":r.get::<_,Option<String>>(6)?,
                "notes":r.get::<_,Option<String>>(7)?,
                "last_name":r.get::<_,Option<String>>(8)?, "patronymic":r.get::<_,Option<String>>(9)?,
                "department":r.get::<_,Option<String>>(10)?, "nickname":r.get::<_,Option<String>>(11)?,
                "photo_revision":r.get::<_,Option<i64>>(12)?
            }))
        })?;
        Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
    }
    pub fn meetings(&self) -> Result<Value> {
        let mut stmt = self
            .0
            .prepare("SELECT id,title,status,created_at FROM meetings ORDER BY id")?;
        let rows = stmt.query_map([], |r| Ok(json!({"id":r.get::<_,i64>(0)?,"title":r.get::<_,String>(1)?,"status":r.get::<_,String>(2)?,"created_at":r.get::<_,String>(3)?})))?;
        Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
    }
    pub fn enqueue(&self, meeting: i64) -> Result<i64> {
        let demo: bool =
            self.0
                .query_row("SELECT is_demo FROM meetings WHERE id=?1", [meeting], |r| {
                    r.get(0)
                })?;
        if demo {
            bail!("Демонстрационная встреча не обрабатывается реальными моделями");
        }
        self.0
            .execute(
                "INSERT INTO processing_jobs(meeting_id,kind) VALUES (?1,'transcribe')",
                [meeting],
            )
            .context("cannot queue job: meeting must exist and have no active transcription job")?;
        Ok(self.0.last_insert_rowid())
    }
    pub fn jobs(&self) -> Result<Value> {
        let mut stmt = self.0.prepare(
            "SELECT id,meeting_id,kind,status,attempts,error,stage,started_at,finished_at FROM processing_jobs ORDER BY id",
        )?;
        let rows = stmt.query_map([], |r| Ok(json!({"id":r.get::<_,i64>(0)?,"meeting_id":r.get::<_,i64>(1)?,"kind":r.get::<_,String>(2)?,"status":r.get::<_,String>(3)?,"attempts":r.get::<_,i64>(4)?,"error":r.get::<_,Option<String>>(5)?,"stage":r.get::<_,Option<String>>(6)?,"started_at":r.get::<_,Option<i64>>(7)?,"finished_at":r.get::<_,Option<i64>>(8)?})))?;
        Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
    }
    pub fn retry(&self, id: i64) -> Result<()> {
        if self.0.execute("UPDATE processing_jobs SET status='pending',error=NULL,stage=NULL,started_at=NULL,finished_at=NULL WHERE id=?1 AND status='failed'", params![id])? != 1 {
            bail!("job {id} does not exist or is not failed");
        }
        Ok(())
    }
    pub fn export(&self, id: i64) -> Result<Value> {
        let mut meeting = self.0.query_row(
            "SELECT m.title,m.status,m.created_at,m.scheduled_at,m.project_id,
                (SELECT min(created_at) FROM capture_sources WHERE meeting_id=m.id),
                json_extract(p.data_json,'$.title')
             FROM meetings m LEFT JOIN projects p ON p.id=m.project_id WHERE m.id=?1", [id], |r| {
            Ok(json!({"id":id,"title":r.get::<_,String>(0)?,"status":r.get::<_,String>(1)?,"created_at":r.get::<_,String>(2)?,
                "scheduled_at":r.get::<_,Option<String>>(3)?,"project_id":r.get::<_,Option<i64>>(4)?,
                "recorded_at":r.get::<_,Option<String>>(5)?,"project_name":r.get::<_,Option<String>>(6)?}))
        }).context("meeting not found")?;
        let analysis = self.groq_analysis(id)?;
        let timezone = self.workspace_timezone()?.parse().unwrap_or(chrono_tz::Europe::Moscow);
        crate::groq::decorate_meeting_protocol(&mut meeting, &analysis, timezone);
        let timeline = self.audio_inputs(id)?;
        let mut transcript = self.transcript(id)?;
        if let Some(run) = transcript["model_run_id"].as_i64() {
            let raw: String = self.0.query_row(
                "SELECT inputs_json FROM model_runs WHERE id=?1",
                [run],
                |r| r.get(0),
            )?;
            let inputs: Value = serde_json::from_str(&raw)?;
            transcript["needs_update"] =
                json!(inputs.as_array().map_or(0, Vec::len) != timeline.len());
        }
        Ok(
            json!({"audio_timeline":timeline,"schema_version":1,"meeting":meeting,"analysis":analysis,"manual_notes":self.meeting_notes(id)?,"recordings":self.recordings(id)?,"fragments":self.fragments(id)?,"transcript":transcript,"live":self.live_snapshot(id)?}),
        )
    }
}
fn validate_text(text: &str) -> Result<()> {
    if text.trim().is_empty() {
        bail!("name/title must not be empty");
    }
    Ok(())
}
