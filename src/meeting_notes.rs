//! Manual meeting results, independent of immutable speech model versions.
use crate::Store;
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

pub(crate) fn read(c: &Connection, meeting: i64) -> Result<Value> {
    let current: Option<(String, i64, String)> = c
        .query_row(
            "SELECT data_json,revision,updated_at FROM meeting_notes WHERE meeting_id=?1",
            [meeting],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    if let Some((raw, revision, updated)) = current {
        let mut value: Value = serde_json::from_str(&raw)?;
        value["revision"] = json!(revision);
        value["updated_at"] = json!(updated);
        Ok(value)
    } else {
        Ok(
            json!({"summary":"","open_questions":"","revision":0,"author_id":null,"author_name":null,"source":"local_workspace","updated_at":null}),
        )
    }
}

pub(crate) fn save(c: &Connection, body: &Value, demo: bool, actor: Option<i64>) -> Result<Value> {
    let meeting = body["meeting_id"].as_i64().context("Не указана встреча")?;
    let scope: bool = c
        .query_row("SELECT is_demo FROM meetings WHERE id=?1", [meeting], |r| {
            r.get(0)
        })
        .context("Встреча не найдена")?;
    if scope != demo {
        bail!("Итоги относятся к другому режиму данных");
    }
    let revision = body["revision"]
        .as_i64()
        .filter(|r| *r >= 0)
        .context("Не указана версия итогов")?;
    let old = read(c, meeting)?;
    if old["revision"] != revision {
        bail!("Итоги уже изменены в другом окне. Откройте их заново и перенесите свои правки.");
    }
    let summary = body["summary"]
        .as_str()
        .context("Резюме должно быть текстом")?
        .trim();
    let questions = body["open_questions"]
        .as_str()
        .context("Открытые вопросы должны быть текстом")?
        .trim();
    if summary.chars().count() > 20_000 || questions.chars().count() > 10_000 {
        bail!("Слишком длинные итоги: резюме до 20000, вопросы до 10000 символов");
    }
    if old["summary"] == summary && old["open_questions"] == questions {
        return Ok(old);
    }
    let author_name = if let Some(id) = actor {
        let (name, author_scope): (String, bool) =
            c.query_row("SELECT name,is_demo FROM people WHERE id=?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?;
        if author_scope != demo {
            bail!("Автор относится к другому режиму данных");
        }
        name
    } else {
        "Локальный пользователь".into()
    };
    let data = json!({"summary":summary,"open_questions":questions,"author_id":actor,"author_name":author_name,"source":"local_workspace"});
    if revision == 0 {
        c.execute("INSERT INTO meeting_notes(meeting_id,data_json,revision) VALUES (?1,?2,1)", params![meeting, data.to_string()])?;
    } else if c.execute("UPDATE meeting_notes SET data_json=?2,revision=revision+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE meeting_id=?1 AND revision=?3", params![meeting, data.to_string(), revision])? != 1 {
        bail!("Конфликт версий итогов");
    }
    let result = read(c, meeting)?;
    c.execute("INSERT INTO change_events(entity_type,entity_id,previous_json,next_json) VALUES ('meeting_notes',?1,?2,?3)", params![meeting, old.to_string(), result.to_string()])?;
    Ok(result)
}

pub(crate) fn history(c: &Connection, meeting: i64, demo: bool) -> Result<Value> {
    let scope: bool = c.query_row("SELECT is_demo FROM meetings WHERE id=?1", [meeting], |r| {
        r.get(0)
    })?;
    if scope != demo {
        bail!("История относится к другому режиму данных");
    }
    let mut stmt = c.prepare("SELECT previous_json,next_json,created_at FROM change_events WHERE entity_type='meeting_notes' AND entity_id=?1 ORDER BY id DESC LIMIT 50")?;
    let rows = stmt.query_map([meeting], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut values = Vec::new();
    for row in rows {
        let (before, after, at) = row?;
        values.push(json!({"before":serde_json::from_str::<Value>(&before)?,"after":serde_json::from_str::<Value>(&after)?,"created_at":at}));
    }
    Ok(json!(values))
}
impl Store {
    pub fn meeting_notes(&self, meeting: i64) -> Result<Value> {
        read(&self.0, meeting)
    }
}
