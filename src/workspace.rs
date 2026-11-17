//! Shared VTASK workspace. UI adapters consume snapshots and transactional commands.
use crate::Store;
use anyhow::{bail, Context, Result};
use chrono::{DateTime, Days, Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use chrono_tz::Tz;
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

pub fn default_stages() -> Value {
    json!([{"id":"todo","title":"К выполнению","kind":"active"},{"id":"doing","title":"В работе","kind":"active"},{"id":"review","title":"На проверке","kind":"active"},{"id":"done","title":"Готово","kind":"done"},{"id":"cancelled","title":"Отменено","kind":"cancelled"}])
}
fn id(v: &Value, key: &str) -> Option<i64> {
    v[key].as_i64()
}
fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or_default()
}
fn person(c: &Connection, value: Option<i64>, demo: bool) -> Result<()> {
    if let Some(value) = value {
        let scope: bool = c
            .query_row("SELECT is_demo FROM people WHERE id=?1", [value], |r| {
                r.get(0)
            })
            .context("Участник не найден")?;
        if scope != demo {
            bail!("Демонстрационные и реальные данные нельзя смешивать");
        }
    }
    Ok(())
}
fn decode_entity(row: &Row<'_>) -> rusqlite::Result<Value> {
    let raw: String = row.get(1)?;
    let mut value: Value = serde_json::from_str(&raw).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(error))
    })?;
    value["id"] = json!(row.get::<_, i64>(0)?);
    value["revision"] = json!(row.get::<_, i64>(2)?);
    value["is_demo"] = json!(row.get::<_, bool>(3)?);
    value["created_at"] = json!(row.get::<_, String>(4)?);
    value["updated_at"] = json!(row.get::<_, String>(5)?);
    Ok(value)
}
fn entity(c: &Connection, table: &str, id: i64) -> Result<Value> {
    c.query_row(
        &format!(
            "SELECT id,data_json,revision,is_demo,created_at,updated_at FROM {table} WHERE id=?1"
        ),
        [id],
        decode_entity,
    )
    .context("Объект не найден")
}
fn entities(c: &Connection, table: &str, demo: bool) -> Result<Vec<Value>> {
    let mut stmt = c.prepare(&format!(
        "SELECT id,data_json,revision,is_demo,created_at,updated_at FROM {table} WHERE is_demo=?1 ORDER BY id"
    ))?;
    let rows = stmt.query_map([demo], decode_entity)?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
}
fn same_scope(v: &Value, demo: bool) -> Result<()> {
    if v["is_demo"] != demo {
        bail!("Объект относится к другому режиму");
    }
    Ok(())
}
fn clean(v: &mut Value) {
    for key in [
        "id",
        "revision",
        "created_at",
        "updated_at",
        "is_demo",
        "active",
        "overdue",
        "due_state",
        "stage_title",
        "stage_kind",
        "task_counts",
    ] {
        v.as_object_mut().unwrap().remove(key);
    }
}
fn save(
    c: &Connection,
    table: &str,
    mut data: Value,
    previous: Option<&Value>,
    demo: bool,
    batch: Option<&str>,
) -> Result<Value> {
    clean(&mut data);
    let entity_id = if let Some(old) = previous {
        let changed = if table == "tasks" {
            c.execute("UPDATE tasks SET data_json=?2,project_id=?3,assignee_id=?4,revision=revision+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?1 AND revision=?5",params![old["id"].as_i64(),data.to_string(),id(&data,"project_id"),id(&data,"assignee_id"),old["revision"].as_i64()])?
        } else {
            c.execute("UPDATE projects SET data_json=?2,revision=revision+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?1 AND revision=?3",params![old["id"].as_i64(),data.to_string(),old["revision"].as_i64()])?
        };
        if changed != 1 {
            bail!("Объект уже изменён. Обновите данные перед сохранением");
        }
        old["id"].as_i64().unwrap()
    } else {
        if table == "tasks" {
            c.execute(
                "INSERT INTO tasks(data_json,project_id,assignee_id,is_demo) VALUES (?1,?2,?3,?4)",
                params![
                    data.to_string(),
                    id(&data, "project_id"),
                    id(&data, "assignee_id"),
                    demo
                ],
            )?;
        } else {
            c.execute(
                "INSERT INTO projects(data_json,is_demo) VALUES (?1,?2)",
                params![data.to_string(), demo],
            )?;
        }
        c.last_insert_rowid()
    };
    let result = entity(c, table, entity_id)?;
    c.execute("INSERT INTO change_events(entity_type,entity_id,batch_id,previous_json,next_json) VALUES (?1,?2,?3,?4,?5)",params![table,entity_id,batch,previous.map(Value::to_string),result.to_string()])?;
    Ok(result)
}
fn date(value: &str) -> Result<NaiveDate> {
    let d = NaiveDate::parse_from_str(value, "%Y-%m-%d").context("Некорректная дата")?;
    if d.to_string() != value {
        bail!("Используйте дату ГГГГ-ММ-ДД");
    }
    Ok(d)
}
/// Date-only deadlines expire at next local midnight, including DST transitions.
pub fn due_state(
    due: Option<&str>,
    time: Option<&str>,
    active: bool,
    now: DateTime<Utc>,
    tz: Tz,
) -> Result<&'static str> {
    if !active {
        return Ok("closed");
    }
    let Some(due) = due.filter(|s| !s.is_empty()) else {
        return Ok("none");
    };
    let day = date(due)?;
    let explicit_time = time.filter(|s| !s.is_empty());
    let boundary = if let Some(time) = explicit_time {
        day.and_time(NaiveTime::parse_from_str(time, "%H:%M").context("Некорректное время срока")?)
    } else {
        day.checked_add_days(Days::new(1))
            .context("Дата вне диапазона")?
            .and_hms_opt(0, 0, 0)
            .unwrap()
    };
    let deadline = if explicit_time.is_some() {
        tz.from_local_datetime(&boundary)
            .latest()
            .context("Указанное время не существует в выбранном часовом поясе")?
    } else {
        // Some zones change clocks at midnight; a date-only deadline still has a valid end of day.
        (0..=2880)
            .find_map(|minutes| {
                boundary
                    .checked_add_signed(Duration::minutes(minutes))
                    .and_then(|local| tz.from_local_datetime(&local).earliest())
            })
            .context("Дата вне диапазона часового пояса")?
    };
    if now >= deadline.with_timezone(&Utc) {
        Ok("overdue")
    } else if day == now.with_timezone(&tz).date_naive() {
        Ok("today")
    } else {
        Ok("upcoming")
    }
}
fn valid_stages(stages: &Value) -> Result<()> {
    let list = stages.as_array().context("Нужен список этапов")?;
    if list.is_empty() || list.len() > 30 {
        bail!("Нужно от 1 до 30 этапов");
    }
    let mut ids = HashSet::new();
    let mut done = false;
    let mut cancelled = false;
    let mut active = false;
    for s in list {
        if text(s, "id").is_empty()
            || text(s, "title").trim().is_empty()
            || !ids.insert(text(s, "id"))
        {
            bail!("У каждого этапа нужны уникальный ID и название");
        }
        match text(s, "kind") {
            "active" => active = true,
            "done" => done = true,
            "cancelled" => cancelled = true,
            _ => bail!("Неизвестный системный тип этапа"),
        }
    }
    if !done || !cancelled || !active {
        bail!("Нужны рабочий, завершённый и отменённый этапы");
    }
    Ok(())
}
fn stages(c: &Connection, task: &Value, demo: bool) -> Result<Value> {
    if let Some(project) = id(task, "project_id") {
        let p = entity(c, "projects", project)?;
        same_scope(&p, demo)?;
        Ok(p["stages"].clone())
    } else {
        Ok(default_stages())
    }
}
fn validate_source(c: &Connection, source: &Value, demo: bool) -> Result<()> {
    let meeting = id(source, "meeting_id").context("Источник должен содержать встречу")?;
    let mode: bool = c
        .query_row("SELECT is_demo FROM meetings WHERE id=?1", [meeting], |r| {
            r.get(0)
        })
        .context("Встреча-источник не найдена")?;
    if mode != demo
        || source["start_ms"].as_u64().is_none()
        || text(source, "quote").trim().is_empty()
    {
        bail!("Нужны исходная цитата и временная метка встречи из текущего режима");
    }
    Ok(())
}
fn validate_task(c: &Connection, v: &mut Value, demo: bool, own: Option<i64>) -> Result<()> {
    for key in ["project_id", "assignee_id", "author_id"] {
        if !v[key].is_null() && v[key].as_i64().is_none() {
            bail!("Некорректный идентификатор: {key}");
        }
    }
    for key in ["due_date", "due_time"] {
        if !v[key].is_null() && !v[key].is_string() {
            bail!("Некорректный срок");
        }
    }
    for key in ["sources", "dependencies"] {
        if v[key].is_null() {
            v[key] = json!([]);
        }
        if !v[key].is_array() {
            bail!("Поле {key} должно быть списком");
        }
    }
    if !v["blocked"].is_boolean() {
        bail!("Некорректный признак блокировки");
    }
    if v["description"].is_null() {
        v["description"] = json!("");
    }
    if !v["description"].is_string() || text(v, "description").len() > 30000 {
        bail!("Описание слишком длинное или некорректное");
    }
    if text(v, "title").trim().is_empty() || text(v, "title").len() > 500 {
        bail!("Укажите название задачи (до 500 символов)");
    }
    v["title"] = json!(text(v, "title").trim());
    person(c, id(v, "assignee_id"), demo)?;
    person(c, id(v, "author_id"), demo)?;
    let pipeline = stages(c, v, demo)?;
    if !pipeline
        .as_array()
        .unwrap()
        .iter()
        .any(|s| s["id"] == v["stage_id"])
    {
        bail!("Этап не принадлежит выбранному проекту");
    }
    if !["low", "normal", "high", "critical"].contains(&text(v, "priority")) {
        bail!("Неизвестный приоритет");
    }
    if let Some(d) = v["due_date"].as_str().filter(|s| !s.is_empty()) {
        date(d)?;
    }
    if let Some(t) = v["due_time"].as_str().filter(|s| !s.is_empty()) {
        NaiveTime::parse_from_str(t, "%H:%M")?;
        if v["due_date"].as_str().unwrap_or_default().is_empty() {
            bail!("Для времени нужна дата");
        }
    }
    let prefs = settings(c)?;
    let tz: Tz = text(&prefs, "timezone").parse()?;
    due_state(
        v["due_date"].as_str(),
        v["due_time"].as_str(),
        true,
        Utc::now(),
        tz,
    )?;
    if v["blocked"] == true && text(v, "blocked_reason").trim().is_empty() {
        bail!("Укажите причину блокировки");
    }
    if let Some(sources) = v["sources"].as_array() {
        for source in sources {
            validate_source(c, source, demo)?;
        }
    }
    if let Some(deps) = v["dependencies"].as_array() {
        let mut visited = HashSet::new();
        let mut stack = Vec::new();
        for dep in deps {
            stack.push(dep.as_i64().context("Некорректная зависимость")?);
        }
        while let Some(dep) = stack.pop() {
            if Some(dep) == own {
                bail!("Зависимости образуют цикл");
            }
            if !visited.insert(dep) {
                continue;
            }
            if visited.len() > 10000 {
                bail!("Слишком много зависимостей");
            }
            let task = entity(c, "tasks", dep)?;
            same_scope(&task, demo)?;
            if let Some(list) = task["dependencies"].as_array() {
                for d in list {
                    stack.push(d.as_i64().context("Некорректная зависимость")?);
                }
            }
        }
    }
    Ok(())
}
fn task_save(c: &Connection, body: &Value, demo: bool, batch: Option<&str>) -> Result<Value> {
    let old = if let Some(i) = id(body, "id") {
        let old = entity(c, "tasks", i)?;
        same_scope(&old, demo)?;
        if body["revision"] != old["revision"] {
            bail!("Задача уже изменена. Обновите данные");
        }
        Some(old)
    } else {
        None
    };
    let mut data = body["data"].clone();
    if !data.is_object() {
        bail!("Нужны поля задачи");
    }
    validate_task(c, &mut data, demo, old.as_ref().and_then(|v| id(v, "id")))?;
    save(c, "tasks", data, old.as_ref(), demo, batch)
}
fn project_save(c: &Connection, body: &Value, demo: bool) -> Result<Value> {
    let old = if let Some(i) = id(body, "id") {
        let p = entity(c, "projects", i)?;
        same_scope(&p, demo)?;
        if p["revision"] != body["revision"] {
            bail!("Проект уже изменён. Обновите данные");
        }
        Some(p)
    } else {
        None
    };
    let mut data = body["data"].clone();
    if !data.is_object() || text(&data, "title").trim().is_empty() {
        bail!("Укажите название проекта");
    }
    data["title"] = json!(text(&data, "title").trim());
    for (key, limit) in [
        ("goal", 4000),
        ("next_milestone", 500),
        ("blocker", 4000),
        ("materials", 8000),
    ] {
        let value = match data.get(key) {
            None => old
                .as_ref()
                .and_then(|p| p.get(key))
                .and_then(Value::as_str)
                .unwrap_or_default(),
            Some(Value::Null) => "",
            Some(Value::String(s)) => s.trim(),
            _ => bail!("Поле проекта {key} должно быть текстом"),
        };
        if value.chars().count() > limit {
            bail!("Поле проекта {key} превышает {limit} символов");
        }
        data[key] = json!(value);
    }
    if data.get("next_milestone_date").is_none() {
        data["next_milestone_date"] = old
            .as_ref()
            .map(|p| p["next_milestone_date"].clone())
            .unwrap_or(Value::Null);
    }
    match &data["next_milestone_date"] {
        Value::Null => {}
        Value::String(value) if value.is_empty() => data["next_milestone_date"] = Value::Null,
        Value::String(value) => {
            date(value)?;
            if text(&data, "next_milestone").is_empty() {
                bail!("Укажите название ближайшего этапа для его срока");
            }
        }
        _ => bail!("Срок ближайшего этапа должен быть датой"),
    }
    person(c, id(&data, "owner_id"), demo)?;
    if !["planned", "active", "paused", "completed", "cancelled"].contains(&text(&data, "status")) {
        bail!("Неизвестный статус проекта");
    }
    if data["stages"].is_null() {
        data["stages"] = default_stages();
    }
    valid_stages(&data["stages"])?;
    for key in ["start_date", "end_date"] {
        if let Some(d) = data[key].as_str().filter(|s| !s.is_empty()) {
            date(d)?;
        }
    }
    if let (Some(start), Some(end)) = (data["start_date"].as_str(), data["end_date"].as_str()) {
        if !start.is_empty() && !end.is_empty() && start > end {
            bail!("Дата завершения раньше начала");
        }
    }
    if let Some(members) = data["members"].as_array() {
        for member in members {
            person(
                c,
                Some(member.as_i64().context("Некорректный участник")?),
                demo,
            )?;
        }
    }
    data["archived"] = json!(old.as_ref().is_some_and(|p| p["archived"] == true));
    let result = save(c, "projects", data, old.as_ref(), demo, None)?;
    if old.is_some() {
        let valid: HashSet<_> = result["stages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| text(s, "id"))
            .collect();
        for mut task in entities(c, "tasks", demo)?
            .into_iter()
            .filter(|t| t["project_id"] == result["id"])
        {
            let previous = task.clone();
            if !valid.contains(text(&task, "stage_id")) {
                let target = text(&body["migrate_stages"], text(&task, "stage_id"));
                if !valid.contains(target) {
                    bail!("Для удаляемого занятого этапа выберите этап переноса задач");
                }
                task["stage_id"] = json!(target);
                save(c, "tasks", task, Some(&previous), demo, None)?;
            }
        }
    }
    Ok(result)
}
fn settings(c: &Connection) -> Result<Value> {
    let raw: Option<String> = c
        .query_row(
            "SELECT data_json FROM workspace_settings WHERE key='preferences'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(match raw {
        Some(s) => serde_json::from_str(&s)?,
        None => {
            json!({"timezone":"Europe/Moscow","me_id":null,"theme":"system","font_size":16,"auto_process":true,"saved_views":[],"initialized":false})
        }
    })
}
fn annotate(task: &mut Value, stages: &Value, now: DateTime<Utc>, tz: Tz) -> Result<()> {
    let stage = stages
        .as_array()
        .context("Этапы проекта не найдены")?
        .iter()
        .find(|s| s["id"] == task["stage_id"])
        .context("Этап задачи не найден")?;
    let active = stage["kind"] == "active";
    let state = due_state(
        task["due_date"].as_str(),
        task["due_time"].as_str(),
        active,
        now,
        tz,
    )?;
    task["active"] = json!(active);
    task["overdue"] = json!(state == "overdue");
    task["due_state"] = json!(state);
    task["stage_title"] = stage["title"].clone();
    task["stage_kind"] = stage["kind"].clone();
    Ok(())
}
#[derive(Default)]
struct TaskCounts {
    total: usize,
    active: usize,
    overdue: usize,
    done: usize,
}
impl TaskCounts {
    fn add(&mut self, task: &Value) {
        self.total += 1;
        self.active += usize::from(task["active"] == true);
        self.overdue += usize::from(task["overdue"] == true);
        self.done += usize::from(task["stage_kind"] == "done");
    }
}
impl Store {
    pub fn workspace(&self, demo: bool, at: Option<DateTime<Utc>>) -> Result<Value> {
        let prefs = settings(&self.0)?;
        let now = at.unwrap_or_else(Utc::now);
        let tz: Tz = text(&prefs, "timezone")
            .parse()
            .context("Неизвестный часовой пояс")?;
        let mut tasks = entities(&self.0, "tasks", demo)?;
        let mut projects = entities(&self.0, "projects", demo)?;
        let default_stages = default_stages();
        let stages_by_project: HashMap<_, _> = projects
            .iter()
            .filter_map(|project| id(project, "id").map(|key| (key, &project["stages"])))
            .collect();
        let mut task_counts = HashMap::<i64, TaskCounts>::new();
        for task in &mut tasks {
            let project_id = id(task, "project_id");
            let stages = match project_id {
                Some(key) => stages_by_project
                    .get(&key)
                    .copied()
                    .context("Объект не найден")?,
                None => &default_stages,
            };
            annotate(task, stages, now, tz)?;
            if let Some(key) = project_id {
                task_counts.entry(key).or_default().add(task);
            }
        }
        for project in &mut projects {
            let counts = task_counts
                .remove(&project["id"].as_i64().unwrap())
                .unwrap_or_default();
            project["task_counts"] = json!({
                "total": counts.total,
                "active": counts.active,
                "overdue": counts.overdue,
                "done": counts.done
            });
            project["overdue"] = json!(
                due_state(
                    project["end_date"].as_str(),
                    None,
                    project["archived"] != true
                        && !["completed", "cancelled"].contains(&text(project, "status")),
                    now,
                    tz
                )? == "overdue"
            );
        }
        let mut people = self.people()?.as_array().unwrap().clone();
        let person_ids: HashSet<i64> = {
            let mut stmt = self.0.prepare("SELECT id FROM people WHERE is_demo=?1")?;
            let rows = stmt.query_map([demo], |r| r.get(0))?;
            rows.collect::<rusqlite::Result<HashSet<_>>>()?
        };
        people.retain(|p| person_ids.contains(&p["id"].as_i64().unwrap()));
        let mut meetings = Vec::new();
        let mut stmt=self.0.prepare("SELECT id,title,status,created_at,project_id,scheduled_at FROM meetings WHERE is_demo=?1 ORDER BY id DESC")?;
        let rows=stmt.query_map([demo],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"title":r.get::<_,String>(1)?,"status":r.get::<_,String>(2)?,"created_at":r.get::<_,String>(3)?,"project_id":r.get::<_,Option<i64>>(4)?,"scheduled_at":r.get::<_,Option<String>>(5)?,"is_demo":demo})))?;
        // Jobs are ordered by ID. Inserting in that order keeps the latest job per meeting.
        let Value::Array(jobs) = self.jobs()? else {
            unreachable!("jobs always returns an array");
        };
        let mut latest_job: HashMap<_, _> = jobs
            .into_iter()
            .filter_map(|job| id(&job, "meeting_id").map(|key| (key, job)))
            .collect();
        for row in rows {
            let mut m = row?;
            let mid = m["id"].as_i64().unwrap();
            let mut q = self
                .0
                .prepare("SELECT person_id FROM meeting_people WHERE meeting_id=?1")?;
            m["participants"] = json!(q
                .query_map([mid], |r| r.get::<_, i64>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?);
            m["recordings"] = self.recordings(mid)?;
            m["manual_notes"] = self.meeting_notes(mid)?;
            m["analysis"] = self.groq_analysis(mid)?;
            m["processing"] = latest_job.remove(&mid).unwrap_or(Value::Null);
            meetings.push(m);
        }
        let mut proposals = Vec::new();
        let mut stmt=self.0.prepare("SELECT id,data_json,status,created_at FROM proposals WHERE is_demo=?1 ORDER BY id DESC")?;
        for row in stmt.query_map([demo], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })? {
            let (i, raw, status, created) = row?;
            let mut p: Value = serde_json::from_str(&raw)?;
            p["id"] = json!(i);
            p["status"] = json!(status);
            p["created_at"] = json!(created);
            proposals.push(p);
        }
        let mut stmt=self.0.prepare("SELECT id,project_id,meeting_id,text,source_json FROM decisions WHERE is_demo=?1 ORDER BY id DESC")?;
        let decisions=stmt.query_map([demo],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,Option<i64>>(1)?,r.get::<_,Option<i64>>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?)))?.collect::<rusqlite::Result<Vec<_>>>()?.into_iter().map(|(i,p,m,t,s)|Ok(json!({"id":i,"project_id":p,"meeting_id":m,"text":t,"source":serde_json::from_str::<Value>(&s)?}))).collect::<Result<Vec<Value>>>()?;
        Ok(
            json!({"schema_version":1,"mode":if demo {"demo"}else{"real"},"now":now.to_rfc3339(),"today":now.with_timezone(&tz).date_naive().to_string(),"settings":prefs,"default_stages":default_stages,"people":people,"projects":projects,"tasks":tasks,"meetings":meetings,"proposals":proposals,"decisions":decisions}),
        )
    }
    pub fn workspace_action(&self, body: &Value) -> Result<Value> {
        if body.get("demo").is_some_and(|v| !v.is_boolean()) {
            bail!("Некорректный режим данных");
        }
        let demo = body["demo"].as_bool().unwrap_or(false);
        if text(body, "op") == "seed_demo" {
            return self.seed_demo();
        }
        let tx = self.0.unchecked_transaction()?;
        let result = match text(body, "op") {
            "save_meeting_notes" => {
                let prefs = settings(&tx)?;
                crate::meeting_notes::save(
                    &tx,
                    body,
                    demo,
                    id(&prefs, if demo { "demo_me_id" } else { "me_id" }),
                )?
            }
            "meeting_notes_history" => crate::meeting_notes::history(
                &tx,
                id(body, "meeting_id").context("Не указана встреча")?,
                demo,
            )?,
            "save_task" => task_save(&tx, body, demo, None)?,
            "save_project" => project_save(&tx, body, demo)?,
            "archive_project" => {
                let old = entity(&tx, "projects", id(body, "id").context("Укажите проект")?)?;
                same_scope(&old, demo)?;
                if old["revision"] != body["revision"] {
                    bail!("Проект уже изменён. Обновите данные");
                }
                let archived = body["archived"]
                    .as_bool()
                    .context("Укажите состояние архива")?;
                let mut data = old.clone();
                data["archived"] = json!(archived);
                save(&tx, "projects", data, Some(&old), demo, None)?
            }
            "settings" => {
                let mut prefs = settings(&tx)?;
                let changes = body["data"].as_object().context("Нужны настройки")?;
                for (key, value) in changes {
                    if ![
                        "timezone",
                        "me_id",
                        "demo_me_id",
                        "theme",
                        "font_size",
                        "auto_process",
                        "saved_views",
                        "initialized",
                    ]
                    .contains(&key.as_str())
                    {
                        bail!("Неизвестная настройка");
                    }
                    prefs[key] = value.clone();
                }
                text(&prefs, "timezone")
                    .parse::<Tz>()
                    .context("Неизвестный часовой пояс")?;
                if !["system", "light", "dark"].contains(&text(&prefs, "theme")) {
                    bail!("Неизвестная тема");
                }
                if !(14..=24).contains(&prefs["font_size"].as_u64().unwrap_or(0)) {
                    bail!("Размер текста от 14 до 24");
                }
                if prefs["auto_process"].as_bool().is_none() {
                    bail!("Некорректный режим обработки");
                }
                for key in ["me_id", "demo_me_id"] {
                    if !prefs[key].is_null() && prefs[key].as_i64().is_none() {
                        bail!("Некорректный участник");
                    }
                }
                if !prefs["saved_views"].is_array()
                    || prefs["saved_views"].as_array().unwrap().len() > 50
                {
                    bail!("Некорректные сохранённые выборки");
                }
                let tz: Tz = text(&prefs, "timezone").parse()?;
                for scope in [true, false] {
                    for task in entities(&tx, "tasks", scope)? {
                        due_state(
                            task["due_date"].as_str(),
                            task["due_time"].as_str(),
                            true,
                            Utc::now(),
                            tz,
                        )?;
                    }
                }
                person(&tx, id(&prefs, "me_id"), false)?;
                person(&tx, id(&prefs, "demo_me_id"), true)?;
                tx.execute("INSERT INTO workspace_settings(key,data_json) VALUES ('preferences',?1) ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",[prefs.to_string()])?;
                prefs
            }
            "save_project_decision" => {
                let project_id = id(body, "project_id").context("Выберите проект")?;
                let project = entity(&tx, "projects", project_id)?;
                same_scope(&project, demo)?;
                if project["archived"] == true {
                    bail!("Сначала восстановите проект из архива");
                }
                let decision = text(body, "text").trim();
                if decision.is_empty() {
                    bail!("Введите текст решения");
                }
                tx.execute(
                    "INSERT INTO decisions(project_id,text,source_json,is_demo) VALUES (?1,?2,'null',?3)",
                    params![project_id, decision, demo],
                )?;
                json!({"id":tx.last_insert_rowid()})
            }
            "save_meeting" => {
                let title = text(&body["data"], "title").trim();
                if title.is_empty() {
                    bail!("Укажите название встречи");
                }
                if let Some(p) = id(&body["data"], "project_id") {
                    same_scope(&entity(&tx, "projects", p)?, demo)?;
                }
                let schedule = body["data"]
                    .get("scheduled_at")
                    .map(|value| match value {
                        Value::Null => Ok(None),
                        Value::String(text) => Ok(Some(
                            DateTime::parse_from_rfc3339(text)
                                .context("Укажите корректную дату и время встречи")?
                                .with_timezone(&Utc)
                                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                        )),
                        _ => bail!("Укажите корректную дату и время встречи"),
                    })
                    .transpose()?;
                let mid = if let Some(mid) = id(body, "id") {
                    let scope: bool =
                        tx.query_row("SELECT is_demo FROM meetings WHERE id=?1", [mid], |r| {
                            r.get(0)
                        })?;
                    if scope != demo {
                        bail!("Другой режим встречи");
                    }
                    tx.execute(
                        "UPDATE meetings SET title=?2,project_id=?3 WHERE id=?1",
                        params![mid, title, id(&body["data"], "project_id")],
                    )?;
                    mid
                } else {
                    tx.execute(
                        "INSERT INTO meetings(title,project_id,is_demo) VALUES (?1,?2,?3)",
                        params![title, id(&body["data"], "project_id"), demo],
                    )?;
                    tx.last_insert_rowid()
                };
                if let Some(schedule) = schedule {
                    tx.execute(
                        "UPDATE meetings SET scheduled_at=?2 WHERE id=?1",
                        params![mid, schedule],
                    )?;
                }
                tx.execute("DELETE FROM meeting_people WHERE meeting_id=?1", [mid])?;
                if let Some(participants) = body["data"]["participants"].as_array() {
                    for p in participants {
                        let pid = p.as_i64().context("Некорректный участник")?;
                        person(&tx, Some(pid), demo)?;
                        tx.execute("INSERT OR IGNORE INTO meeting_people(meeting_id,person_id) VALUES (?1,?2)",params![mid,pid])?;
                    }
                }
                json!({"id":mid})
            }
            "add_person" => {
                let name = text(body, "name").trim();
                if name.is_empty() {
                    bail!("Укажите имя");
                }
                tx.execute(
                    "INSERT INTO people(name,is_demo) VALUES (?1,?2)",
                    params![name, demo],
                )?;
                json!({"id":tx.last_insert_rowid()})
            }
            "save_person" => {
                let pid = body["id"].as_i64().context("Выберите участника")?;
                person(&tx, Some(pid), demo)?;
                let data = &body["data"];
                let name = text(data, "name").trim();
                if name.is_empty() {
                    bail!("Укажите имя");
                }
                let role = text(data, "role").trim();
                let organization = text(data, "organization").trim();
                let email = text(data, "email").trim();
                let phone = text(data, "phone").trim();
                let notes = text(data, "notes").trim();
                let last_name = data["last_name"].as_str().map(str::trim);
                let patronymic = data["patronymic"].as_str().map(str::trim);
                let department = data["department"].as_str().map(str::trim);
                let nickname = data["nickname"].as_str().map(str::trim);
                if [name, role, organization, email, phone, last_name.unwrap_or(""), patronymic.unwrap_or(""),
                    department.unwrap_or(""), nickname.unwrap_or("")]
                    .iter().any(|field| field.chars().count() > 254)
                    || notes.chars().count() > 4000
                {
                    bail!("Поля карточки должны быть до 254 символов, заметки — до 4000");
                }
                tx.execute("UPDATE people SET name=?1 WHERE id=?2", params![name, pid])?;
                tx.execute(
                    "INSERT INTO person_profiles(person_id,role,organization,email,phone,notes,last_name,patronymic,department,nickname)
                     VALUES (?1,?2,?3,?4,?5,?6,COALESCE(?7,''),COALESCE(?8,''),COALESCE(?9,''),COALESCE(?10,''))
                     ON CONFLICT(person_id) DO UPDATE SET role=excluded.role,
                     organization=excluded.organization,email=excluded.email,phone=excluded.phone,notes=excluded.notes,
                     last_name=COALESCE(?7,person_profiles.last_name),patronymic=COALESCE(?8,person_profiles.patronymic),
                     department=COALESCE(?9,person_profiles.department),nickname=COALESCE(?10,person_profiles.nickname)",
                    params![pid, role, organization, email, phone, notes, last_name, patronymic, department, nickname],
                )?;
                json!({"id":pid})
            }
            "batch_tasks" => {
                let items = body["items"].as_array().context("Выберите задачи")?;
                if items.is_empty() || items.len() > 100 {
                    bail!("От 1 до 100 задач за действие");
                }
                let batch = format!(
                    "batch-{}",
                    Utc::now().timestamp_nanos_opt().unwrap_or_default()
                );
                let mut results = Vec::new();
                let mut seen = HashSet::new();
                for item in items {
                    if !seen.insert(id(item, "id")) {
                        bail!("Повтор задачи в группе");
                    }
                    results.push(task_save(&tx, item, demo, Some(&batch))?);
                }
                json!({"batch_id":batch,"tasks":results})
            }
            "undo_batch" => {
                let batch = text(body, "batch_id");
                let mut stmt=tx.prepare("SELECT entity_id,previous_json,next_json FROM change_events WHERE batch_id=?1 ORDER BY id DESC")?;
                let entries = stmt
                    .query_map([batch], |r| {
                        Ok((
                            r.get::<_, i64>(0)?,
                            r.get::<_, Option<String>>(1)?,
                            r.get::<_, String>(2)?,
                        ))
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                if entries.is_empty() {
                    bail!("Группа изменений не найдена");
                }
                for (tid, previous, next) in entries {
                    let current = entity(&tx, "tasks", tid)?;
                    same_scope(&current, demo)?;
                    let next: Value = serde_json::from_str(&next)?;
                    if current["revision"] != next["revision"] {
                        bail!("Отмена невозможна: задача уже изменена после массового действия");
                    }
                    let mut previous: Value = serde_json::from_str(
                        &previous.context("Создание не отменяется этой командой")?,
                    )?;
                    validate_task(&tx, &mut previous, demo, Some(tid))?;
                    save(&tx, "tasks", previous, Some(&current), demo, None)?;
                }
                json!({"undone":true})
            }
            "history" => {
                let table = text(body, "entity");
                if !["tasks", "projects"].contains(&table) {
                    bail!("Неизвестный объект");
                }
                let eid = id(body, "id").context("Объект не выбран")?;
                same_scope(&entity(&tx, table, eid)?, demo)?;
                let mut stmt=tx.prepare("SELECT id,previous_json,next_json,created_at FROM change_events WHERE entity_type=?1 AND entity_id=?2 ORDER BY id DESC")?;
                let rows = stmt
                    .query_map(params![table, eid], |r| {
                        Ok((
                            r.get::<_, i64>(0)?,
                            r.get::<_, Option<String>>(1)?,
                            r.get::<_, String>(2)?,
                            r.get::<_, String>(3)?,
                        ))
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                json!(rows.into_iter().map(|(i,p,n,t)|Ok(json!({"id":i,"before":p.map(|s|serde_json::from_str::<Value>(&s)).transpose()?,"after":serde_json::from_str::<Value>(&n)?,"created_at":t}))).collect::<Result<Vec<_>>>()?)
            }
            "propose" => {
                let p = &body["data"];
                validate_source(&tx, &p["source"], demo)?;
                if ![
                    "create_task",
                    "change_due",
                    "change_assignee",
                    "change_status",
                    "decision",
                ]
                .contains(&text(p, "kind"))
                {
                    bail!("Неизвестный тип предложения");
                }
                let mut p = p.clone();
                p["origin"] = json!("manual");
                tx.execute(
                    "INSERT INTO proposals(data_json,is_demo) VALUES (?1,?2)",
                    params![p.to_string(), demo],
                )?;
                json!({"id":tx.last_insert_rowid()})
            }
            "review" => review(&tx, body, demo)?,
            _ => bail!("Неизвестная команда рабочего пространства"),
        };
        tx.commit()?;
        Ok(result)
    }
    pub fn auto_process_enabled(&self) -> Result<bool> {
        Ok(settings(&self.0)?["auto_process"] == true)
    }
}
fn review(c: &Connection, body: &Value, demo: bool) -> Result<Value> {
    let pid = id(body, "id").context("Предложение не выбрано")?;
    let (raw, status, scope): (String, String, bool) = c.query_row(
        "SELECT data_json,status,is_demo FROM proposals WHERE id=?1",
        [pid],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    if scope != demo || status != "pending" {
        bail!("Предложение уже рассмотрено или относится к другому режиму");
    }
    if body["reject"] == true {
        c.execute("UPDATE proposals SET status='rejected' WHERE id=?1", [pid])?;
        return Ok(json!({"rejected":true}));
    }
    let proposal: Value = serde_json::from_str(&raw)?;
    let source = &proposal["source"];
    // Proposals retain the quoted evidence from the analysis that created them.
    validate_source(c, source, demo)?;
    let approved = &body["data"];
    let mut result = Value::Null;
    match text(&proposal, "kind") {
        "decision" => {
            let decision = text(approved, "title").trim();
            if decision.is_empty() {
                bail!("Укажите решение");
            }
            let project = id(approved, "project_id");
            if let Some(p) = project {
                same_scope(&entity(c, "projects", p)?, demo)?;
            }
            c.execute("INSERT INTO decisions(project_id,meeting_id,text,source_json,is_demo) VALUES (?1,?2,?3,?4,?5)",params![project,id(source,"meeting_id"),decision,source.to_string(),demo])?;
        }
        "create_task" => {
            if let Some(existing) = id(body, "existing_task_id") {
                let old = entity(c, "tasks", existing)?;
                same_scope(&old, demo)?;
                let mut data = old.clone();
                let mut sources = data["sources"].as_array().cloned().unwrap_or_default();
                if !sources.contains(source) {
                    sources.push(source.clone());
                }
                data["sources"] = json!(sources);
                if body["apply_due"] == true {
                    if body["task_revision"] != old["revision"] {
                        bail!("Задача изменилась. Откройте предложение заново");
                    }
                    data["due_date"] = approved["due_date"].clone();
                    data["due_time"] = approved["due_time"].clone();
                    validate_task(c, &mut data, demo, Some(existing))?;
                }
                result = save(c, "tasks", data, Some(&old), demo, None)?;
            } else {
                let mut data = approved.clone();
                data["sources"] = json!([source]);
                result = task_save(c, &json!({"data":data}), demo, None)?;
            }
        }
        kind @ ("change_due" | "change_assignee" | "change_status") => {
            let tid = id(body, "existing_task_id")
                .or_else(|| id(&proposal, "task_id"))
                .context("Выберите существующую задачу")?;
            let old = entity(c, "tasks", tid)?;
            same_scope(&old, demo)?;
            if body["task_revision"] != old["revision"] {
                bail!("Задача изменилась после открытия предложения. Проверьте новые значения");
            }
            let mut data = old.clone();
            for key in match kind {
                "change_due" => vec!["due_date", "due_time"],
                "change_assignee" => vec!["assignee_id"],
                _ => vec!["stage_id"],
            } {
                data[key] = approved[key].clone();
            }
            validate_task(c, &mut data, demo, Some(tid))?;
            result = save(c, "tasks", data, Some(&old), demo, None)?;
        }
        _ => bail!("Неизвестный тип предложения"),
    }
    let mut saved = proposal.clone();
    saved["confirmed_task_id"] = result["id"].clone();
    c.execute(
        "UPDATE proposals SET status='accepted',data_json=?2 WHERE id=?1",
        params![pid, saved.to_string()],
    )?;
    Ok(json!({"accepted":true,"task":result}))
}
impl Store {
    fn seed_demo(&self) -> Result<Value> {
        self.seed_demo_at(Utc::now())
    }
    pub fn seed_demo_at(&self, now: DateTime<Utc>) -> Result<Value> {
        let tx = self.0.unchecked_transaction()?;
        let count: i64 =
            tx.query_row("SELECT count(*) FROM projects WHERE is_demo=1", [], |r| {
                r.get(0)
            })?;
        if count > 0 {
            return Ok(json!({"seeded":false}));
        }
        let tz: Tz = text(&settings(&tx)?, "timezone").parse()?;
        let today = now.with_timezone(&tz).date_naive();
        let day = |offset: i64| (today + Duration::days(offset)).to_string();
        let mut persons = Vec::new();
        for name in ["Участник 1", "Участник 2", "Участник 3"] {
            tx.execute("INSERT INTO people(name,is_demo) VALUES (?1,1)", [name])?;
            persons.push(tx.last_insert_rowid());
        }
        let mut project_ids = Vec::new();
        for (i, title) in [
            "Запуск нового продукта",
            "Обновление сайта",
            "Внутренние процессы",
        ]
        .iter()
        .enumerate()
        {
            let p = project_save(
                &tx,
                &json!({"data":{"title":title,"description":"Демонстрационный проект — данные можно изменять","owner_id":persons[i],"members":persons,"start_date":day(-14),"end_date":day(if i==1{-2}else{21}),"status":if i==2{"paused"}else{"active"},"stages":default_stages()}}),
                true,
            )?;
            project_ids.push(p["id"].as_i64().unwrap());
        }
        let titles = [
            "Согласовать прототип интерфейса",
            "Подготовить план запуска",
            "Проверить гипотезы с клиентами",
            "Обновить спецификацию",
            "Опубликовать итог встречи",
            "Собрать обратную связь",
            "Подготовить тексты страниц",
            "Проверить доступность",
            "Завершить тестовый прогон",
            "Уточнить состав команды",
            "Подготовить бюджет",
            "Согласовать роли",
            "Настроить отчётность",
            "Провести ретроспективу",
            "Закрыть старые поручения",
        ];
        let mut tasks = Vec::new();
        for (i, title) in titles.iter().enumerate() {
            let t = task_save(
                &tx,
                &json!({"data":{"title":title,"description":"Демо-задача. Изменения сохраняются и отражаются во всех представлениях.","project_id":project_ids[i/5],"assignee_id":if i%4==0 {None}else{Some(persons[i%3])},"author_id":persons[0],"stage_id":(["todo","doing","review","done","cancelled"][i%5]),"priority":(["high","normal","low","critical"][i%4]),"due_date":if i%5==2 {None}else{Some(day(if i==6{3}else if i==11{7}else{match i%5{0=>-3,1=>0,3=>-1,_=>4}}))},"due_time":null,"blocked":i==1,"blocked_reason":if i==1{"Ожидаем доступ к материалам"}else{""},"dependencies":[],"sources":[]}}),
                true,
                None,
            )?;
            tasks.push(t);
        }
        let mut meetings = Vec::new();
        for (i, title) in [
            "Планирование запуска",
            "Обсуждение сайта",
            "Командная синхронизация",
        ]
        .iter()
        .enumerate()
        {
            tx.execute("INSERT INTO meetings(title,status,project_id,is_demo) VALUES (?1,'completed',?2,1)",params![title,project_ids[i]])?;
            let mid = tx.last_insert_rowid();
            meetings.push(mid);
            for person in &persons {
                tx.execute(
                    "INSERT INTO meeting_people(meeting_id,person_id) VALUES (?1,?2)",
                    params![mid, person],
                )?;
            }
            tx.execute("INSERT INTO processing_jobs(meeting_id,kind,status,attempts) VALUES (?1,'transcribe','completed',1)",[mid])?;
            let job = tx.last_insert_rowid();
            tx.execute("INSERT INTO model_runs(job_id,meeting_id,model_path,model_sha256,engine_path,engine_sha256,language,status,inputs_json,parameters_json) VALUES (?1,?2,'demo','demo','demo','demo','ru','completed','[]','{\"demonstration\":true}')",params![job,mid])?;
            let run = tx.last_insert_rowid();
            for (index, quote) in [
                "Предлагаю подготовить обновлённый прототип к концу недели.",
                "Нужно уточнить ответственного и срок, затем подтвердить поручение.",
                "Согласовали последовательность работ. Итоги сохраняем в проекте.",
            ]
            .iter()
            .enumerate()
            {
                tx.execute("INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,?2,?3,?4,'[]')",params![run,index*7000,index*7000+6500,quote])?;
                tx.execute("INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id) VALUES (?1,?2,?3,?4)",params![run,index*7000,index*7000+6500,format!("speaker_{}",index%2)])?;
            }
        }
        for (i, kind) in [
            "create_task",
            "change_due",
            "change_assignee",
            "change_status",
            "decision",
        ]
        .iter()
        .enumerate()
        {
            let data = json!({"kind":kind,"origin":"demo_ai","task_id":tasks[i]["id"],"title":if i==0{"Подготовить обновлённый прототип"}else{"Уточнение договорённости"},"description":"Демонстрационное AI-предложение. Изменение не применяется без подтверждения.","project_id":project_ids[i%3],"assignee_id":null,"due_date":null,"due_time":null,"stage_id":"todo","source":{"meeting_id":meetings[i%3],"start_ms":0,"quote":"Предлагаю подготовить обновлённый прототип к концу недели."},"proposed":{"due_date":day(7),"due_time":null,"assignee_id":persons[1],"stage_id":"doing"}});
            tx.execute(
                "INSERT INTO proposals(data_json,is_demo) VALUES (?1,1)",
                [data.to_string()],
            )?;
        }
        let mut prefs = settings(&tx)?;
        prefs["demo_me_id"] = json!(persons[0]);
        tx.execute("INSERT INTO workspace_settings(key,data_json) VALUES ('preferences',?1) ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",[prefs.to_string()])?;
        tx.commit()?;
        Ok(json!({"seeded":true}))
    }
}
