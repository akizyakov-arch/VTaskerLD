//! Manual person assignments are separate from immutable model results.
use crate::Store;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
impl Store {
    pub fn person_photo(&self, id: i64) -> Result<Option<Vec<u8>>> {
        use rusqlite::OptionalExtension;
        Ok(self.0.query_row("SELECT photo FROM person_profiles WHERE person_id=?1", [id],
            |row| row.get::<_, Option<Vec<u8>>>(0)).optional()?.flatten())
    }

    pub fn save_person_photo(&self, id: i64, photo: Option<&[u8]>) -> Result<()> {
        if photo.is_some_and(|data| !data.starts_with(&[0xff, 0xd8, 0xff]) ||
            !data.ends_with(&[0xff, 0xd9]) || data.len() > 512 * 1024)
        {
            bail!("Нужно фото JPEG размером до 512 КБ");
        }
        let updated = self.0.execute(
            "INSERT INTO person_profiles(person_id,photo,photo_revision)
             SELECT id,?2,1 FROM people WHERE id=?1 AND is_demo=0
             ON CONFLICT(person_id) DO UPDATE SET photo=excluded.photo,photo_revision=photo_revision+1",
            rusqlite::params![id, photo],
        )?;
        if updated == 0 { bail!("Участник не найден"); }
        Ok(())
    }

    pub fn assign_speaker(&self, run: i64, speaker: &str, person: Option<i64>) -> Result<i64> {
        let tx = self.0.unchecked_transaction()?;
        let valid: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM speaker_turns t JOIN model_runs m ON m.id=t.model_run_id WHERE t.model_run_id=?1 AND t.speaker_id=?2 AND m.status='completed')",rusqlite::params![run,speaker],|r|r.get(0))?;
        if !valid {
            bail!("speaker does not exist in this completed model run");
        }
        if let Some(person) = person {
            let matches:bool=self.0.query_row("SELECT EXISTS(SELECT 1 FROM people p JOIN model_runs m ON m.id=?1 JOIN meetings meet ON meet.id=m.meeting_id WHERE p.id=?2 AND p.is_demo=meet.is_demo)",rusqlite::params![run,person],|r|r.get(0))?;
            if !matches {
                bail!("Участник не найден в этом режиме данных");
            }
        }
        if let Some(person) = person {
            tx.query_row("SELECT id FROM people WHERE id=?1", [person], |r| {
                r.get::<_, i64>(0)
            })
            .context("person not found")?;
        }
        tx.execute(
            "INSERT INTO speaker_assignments(model_run_id,speaker_id,person_id) VALUES (?1,?2,?3)",
            rusqlite::params![run, speaker, person],
        )?;
        let id = tx.last_insert_rowid();
        tx.commit()?;
        Ok(id)
    }
    pub fn speaker_assignments(&self, run: i64, history: bool) -> Result<Vec<Value>> {
        let filter = if history {
            ""
        } else {
            " AND a.id=(SELECT max(b.id) FROM speaker_assignments b WHERE b.model_run_id=a.model_run_id AND b.speaker_id=a.speaker_id)"
        };
        let mut stmt=self.0.prepare(&format!("SELECT a.id,a.speaker_id,a.person_id,p.name,a.created_at FROM speaker_assignments a LEFT JOIN people p ON p.id=a.person_id WHERE a.model_run_id=?1{filter} ORDER BY a.id"))?;
        let rows=stmt.query_map([run],|r|Ok(json!({"assignment_id":r.get::<_,i64>(0)?,"speaker_id":r.get::<_,String>(1)?,"person_id":r.get::<_,Option<i64>>(2)?,"person_name":r.get::<_,Option<String>>(3)?,"created_at":r.get::<_,String>(4)?})))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
}
pub fn overlay_person(value: &mut Value, assignments: &[Value]) {
    let assignment = assignments
        .iter()
        .find(|a| value["speaker_id"].is_string() && a["speaker_id"] == value["speaker_id"]);
    if assignment.is_some() {
        value["assignment_source"] = json!("manual_speaker");
    }
    value["person_id"] = assignment.map_or(Value::Null, |a| a["person_id"].clone());
    value["person_name"] = assignment.map_or(Value::Null, |a| a["person_name"].clone());
}

impl Store {
    pub fn edit_segment(&self, run: i64, segment: i64, text: &str) -> Result<i64> {
        if text.trim().is_empty() {
            bail!("Текст не должен быть пустым");
        }
        let valid:bool=self.0.query_row("SELECT EXISTS(SELECT 1 FROM segments s JOIN model_runs m ON m.id=s.model_run_id WHERE s.id=?1 AND m.id=?2 AND m.status='completed')",rusqlite::params![segment,run],|r|r.get(0))?;
        if !valid {
            bail!("Фрагмент не найден в завершённой версии");
        }
        self.0.execute(
            "INSERT INTO segment_edits(model_run_id,segment_id,text) VALUES (?1,?2,?3)",
            rusqlite::params![run, segment, text.trim()],
        )?;
        Ok(self.0.last_insert_rowid())
    }
    pub fn assign_segment(&self, run: i64, segment: i64, person: Option<i64>) -> Result<i64> {
        let valid:bool=self.0.query_row("SELECT EXISTS(SELECT 1 FROM segments s JOIN model_runs m ON m.id=s.model_run_id WHERE s.id=?1 AND m.id=?2 AND m.status='completed')",rusqlite::params![segment,run],|r|r.get(0))?;
        if !valid {
            bail!("Фрагмент не найден в завершённой версии");
        }
        if let Some(person) = person {
            let matches:bool=self.0.query_row("SELECT EXISTS(SELECT 1 FROM people p JOIN model_runs m ON m.id=?1 JOIN meetings meet ON meet.id=m.meeting_id WHERE p.id=?2 AND p.is_demo=meet.is_demo)",rusqlite::params![run,person],|r|r.get(0))?;
            if !matches {
                bail!("Участник не найден в этом режиме данных");
            }
        }
        if let Some(person) = person {
            self.0
                .query_row("SELECT id FROM people WHERE id=?1", [person], |r| {
                    r.get::<_, i64>(0)
                })
                .context("Участник не найден")?;
        }
        self.0.execute(
            "INSERT INTO segment_assignments(model_run_id,segment_id,person_id) VALUES (?1,?2,?3)",
            rusqlite::params![run, segment, person],
        )?;
        Ok(self.0.last_insert_rowid())
    }
    pub(crate) fn segment_overlay(&self, run: i64, segment: i64, value: &mut Value) -> Result<()> {
        use rusqlite::OptionalExtension;
        let edit:Option<String>=self.0.query_row("SELECT text FROM segment_edits WHERE model_run_id=?1 AND segment_id=?2 ORDER BY id DESC LIMIT 1",rusqlite::params![run,segment],|r|r.get(0)).optional()?;
        value["original_text"] = value["text"].clone();
        value["manually_edited"] = json!(edit.is_some());
        if let Some(text) = edit {
            value["text"] = json!(text);
        }
        let assignment:Option<(Option<i64>,Option<String>)>=self.0.query_row("SELECT a.person_id,p.name FROM segment_assignments a LEFT JOIN people p ON p.id=a.person_id WHERE a.model_run_id=?1 AND a.segment_id=?2 ORDER BY a.id DESC LIMIT 1",rusqlite::params![run,segment],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((person, name)) = assignment {
            value["person_id"] = json!(person);
            value["person_name"] = json!(name);
            value["assignment_source"] = json!("manual_segment");
        }
        Ok(())
    }
}
