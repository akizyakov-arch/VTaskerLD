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
        "related_task_ids",
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
    if source["type"] == "assistant_command" {
        let quote = text(source, "quote").trim();
        if source["meeting_id"].is_null() && (1..=1000).contains(&quote.chars().count()) {
            return Ok(());
        }
        bail!("Некорректный источник команды Валли");
    }
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

fn assistant_assignee(c: &Connection, name: &str, demo: bool) -> Result<i64> {
    let mut stmt = c.prepare(
        "SELECT p.id,p.name,COALESCE(d.last_name,''),COALESCE(d.patronymic,''),COALESCE(d.nickname,'')
         FROM people p LEFT JOIN person_profiles d ON d.person_id=p.id WHERE p.is_demo=?1",
    )?;
    let normalize = |value: String| value.split_whitespace().collect::<Vec<_>>().join(" ")
        .to_lowercase().replace('ё', "е");
    let people = stmt.query_map([demo], |row| {
        let first = normalize(row.get(1)?);
        let last = normalize(row.get(2)?);
        let patronymic = normalize(row.get(3)?);
        let nickname = normalize(row.get(4)?);
        let full = normalize(format!("{last} {first} {patronymic}"));
        let aliases = [first.clone(), nickname, full, normalize(format!("{last} {first}")),
            normalize(format!("{first} {last}")), normalize(format!("{first} {patronymic} {last}"))];
        Ok((row.get::<_, i64>(0)?, first, aliases))
    })?.collect::<rusqlite::Result<Vec<_>>>()?;
    let exact: Vec<_> = people.iter().filter(|(_, _, aliases)| aliases.iter().any(|value| value == name)).collect();
    let matches = if exact.is_empty() {
        people.iter().filter(|(_, value, _)| {
            let Some(first) = value.split_whitespace().next() else { return false; };
            let dative = if let Some(stem) = first.strip_suffix('а') {
                format!("{stem}у")
            } else if let Some(stem) = first.strip_suffix(['я', 'й', 'ь']) {
                format!("{stem}ю")
            } else {
                format!("{first}у")
            };
            first == name || dative == name
        }).collect()
    } else {
        exact
    };
    let [(id, _, _)] = matches.as_slice() else {
        bail!("Уточните исполнителя. Можно указать имя и фамилию или псевдоним из карточки участника");
    };
    Ok(*id)
}

fn edit_assistant_review_draft(c: &Connection, proposal_id: i64, action: &Value, demo: bool) -> Result<Value> {
    let raw: String = c.query_row(
        "SELECT data_json FROM proposals WHERE id=?1 AND is_demo=?2 AND status='pending'",
        params![proposal_id, demo], |row| row.get(0),
    ).optional()?.context("Предложение уже рассмотрено или недоступно")?;
    let proposal: Value = serde_json::from_str(&raw)?;
    if proposal["kind"] != "create_task" || !matches!(text(action, "kind"), "change_due" | "change_assignee" | "change_task") {
        bail!("Здесь можно изменить срок и исполнителя новой задачи на согласовании");
    }
    let mut draft = proposal.get("review_draft").filter(|draft| draft["data"].is_object()).cloned()
        .unwrap_or_else(|| json!({
            "op":"review", "id":proposal_id, "data":{
                "title":proposal["title"], "description":proposal["description"], "project_id":proposal["project_id"],
                "assignee_id":proposal["assignee_id"], "stage_id":proposal["proposed"]["stage_id"],
                "due_date":proposal["due_date"], "due_time":proposal["due_time"],
                "related_task_id":proposal["related_task_id"], "priority":"normal", "blocked":false
            }
        }));
    let project = id(&draft["data"], "project_id").map(|id| entity(c, "projects", id)).transpose()?;
    if project.as_ref().is_some_and(|project| project["archived"] == true) {
        bail!("Задача относится к архивному проекту");
    }
    if text(&draft["data"], "stage_id").is_empty() {
        let stages = stages(c, &draft["data"], demo)?;
        draft["data"]["stage_id"] = stages.as_array().into_iter().flatten()
            .find(|stage| stage["kind"] == "active").map(|stage| stage["id"].clone()).unwrap_or_default();
    }
    if action["due_date"].is_string() {
        draft["data"]["due_date"] = action["due_date"].clone();
        draft["data"]["due_time"] = action["due_time"].clone();
        if id(&draft, "existing_task_id").is_some() { draft["apply_due"] = json!(true); }
    }
    if let Some(name) = action["assignee_name"].as_str() {
        draft["data"]["assignee_id"] = json!(assistant_assignee(c, name, demo)?);
        if id(&draft, "existing_task_id").is_some() { draft["apply_assignee"] = json!(true); }
    }
    c.execute(
        "UPDATE proposals SET data_json=json_set(data_json,'$.review_draft',json(?2)) WHERE id=?1 AND is_demo=?3 AND status='pending'",
        params![proposal_id, draft.to_string(), demo],
    )?;
    Ok(json!({"id":proposal_id}))
}

fn assistant_task_update(changes: &Value) -> Result<Value> {
    let fields = changes.as_object().context("Некорректные параметры изменения задачи")?;
    if fields.keys().any(|key| !matches!(key.as_str(), "due_date" | "due_time" | "assignee"))
        || fields.values().any(|value| !value.is_string()) {
        bail!("Можно указать только срок, время и имя исполнителя");
    }
    let date = changes["due_date"].as_str().map(|value| {
        let date = NaiveDate::parse_from_str(value, "%Y-%m-%d").context("Уточните дату срока")?;
        if value.len() != 10 || date.format("%Y-%m-%d").to_string() != value { bail!("Уточните дату срока"); }
        Ok(date.to_string())
    }).transpose()?;
    let time = changes["due_time"].as_str().map(|value| {
        if date.is_none() || value.len() != 5 { bail!("Укажите дату и время срока"); }
        let time = NaiveTime::parse_from_str(value, "%H:%M").context("Уточните время срока")?;
        Ok(time.format("%H:%M").to_string())
    }).transpose()?;
    let name = changes["assignee"].as_str().map(|value| {
        let value = value.trim();
        if value.is_empty() || value.chars().count() > 120 { bail!("Уточните имя исполнителя"); }
        Ok(value.to_lowercase().replace('ё', "е"))
    }).transpose()?;
    let kind = match (date.is_some(), name.is_some()) {
        (true, true) => "change_task",
        (true, false) => "change_due",
        (false, true) => "change_assignee",
        (false, false) => bail!("Уточните срок или исполнителя"),
    };
    Ok(json!({"kind":kind,"due_date":date,"due_time":time,"assignee_name":name}))
}

fn propose_assistant_command(c: &Connection, request: &Value, demo: bool) -> Result<Value> {
    let quote = text(request, "text").trim();
    if quote.chars().count() > 1000 { bail!("Команда должна быть до 1000 символов"); }
    let timezone: Tz = text(&settings(c)?, "timezone").parse()?;
    let today = Utc::now().with_timezone(&timezone).date_naive();
    let target_id = id(request, "task_id");
    let draft_id = id(request, "proposal_id");
    if target_id.is_some() && draft_id.is_some() { bail!("Выберите одну задачу"); }
    let selected_action = || {
        if let Some(changes) = request.get("changes") {
            if quote.is_empty() { bail!("Укажите исходную команду Валли"); }
            return assistant_task_update(changes);
        }
        crate::local_analysis::parse_action(quote, Some(today))
            .context("Уточните команду, например «Перенеси срок на завтра в 16:30»")
    };
    if let Some(proposal_id) = draft_id {
        return edit_assistant_review_draft(c, proposal_id, &selected_action()?, demo);
    }
    let (task_id, action) = if let Some(task_id) = target_id {
        (task_id, selected_action()?)
    } else {
        if request.get("changes").is_some() { bail!("Сначала выберите задачу"); }
        crate::local_analysis::parse_command(quote, Some(today)).context(
            "Откройте задачу или укажите её номер, например «По задаче #42: перенести срок на завтра в 16:30»",
        )?
    };
    let task = entity(c, "tasks", task_id)?;
    same_scope(&task, demo)?;
    if let Some(project_id) = id(&task, "project_id") {
        if entity(c, "projects", project_id)?["archived"] == true {
            bail!("Задача относится к архивному проекту");
        }
    }
    let kind = text(&action, "kind");
    if kind == "change_task" && !stages(c, &task, demo)?.as_array().into_iter().flatten()
        .any(|stage| stage["id"] == task["stage_id"] && stage["kind"] == "active") {
        bail!("Срок и исполнителя вместе можно изменить у активной задачи");
    }
    let mut proposal = json!({"kind":kind, "title":task["title"], "project_id":task["project_id"],
        "task_id":task_id,"origin":"assistant_command","source":{"type":"assistant_command","quote":quote}});
    if kind == "create_task" {
        proposal["title"] = action["title"].clone();
        proposal["related_task_id"] = json!(task_id);
        proposal["task_id"] = Value::Null;
    } else {
        let normalized = |title: &str| title.trim().to_lowercase().replace('ё', "е");
        let proposed = match kind {
            "change_due" => json!({"due_date":action["due_date"],"due_time":action["due_time"]}),
            "change_task" => json!({"due_date":action["due_date"],"due_time":action["due_time"],
                "assignee_id":assistant_assignee(c, text(&action,"assignee_name"), demo)?}),
            "change_blocked" => json!({"blocked":action["blocked"],"blocked_reason":text(&action,"blocked_reason")}),
            "change_status" => {
                let matches = stages(c, &task, demo)?;
                let stage = matches.as_array().into_iter().flatten()
                    .find(|stage| normalized(text(stage,"title")) == text(&action,"stage_title"))
                    .context("Укажите название статуса из проекта")?;
                json!({"stage_id":stage["id"],"stage_title":stage["title"]})
            }
            "change_assignee" => json!({"assignee_id":assistant_assignee(c, text(&action,"assignee_name"), demo)?}),
            _ => bail!("Неизвестная команда Валли"),
        };
        let fields = change_fields(kind);
        let baseline: serde_json::Map<_, _> = fields.iter().map(|key| (key.to_string(), task[*key].clone())).collect();
        if fields.iter().all(|key| task[*key] == proposed[*key]) {
            bail!("В задаче уже установлены эти значения");
        }
        proposal["base_task"] = json!(baseline);
        proposal["proposed"] = proposed;
    }
    let raw = proposal.to_string();
    if let Some(existing) = c.query_row(
        "SELECT id FROM proposals WHERE is_demo=?1 AND status='pending'
         AND json_remove(data_json,'$.review_draft')=?2 ORDER BY id DESC LIMIT 1",
        params![demo, raw], |row| row.get::<_,i64>(0),
    ).optional()? {
        return Ok(json!({"id":existing}));
    }
    c.execute("INSERT INTO proposals(data_json,is_demo) VALUES (?1,?2)", params![raw,demo])?;
    Ok(json!({"id":c.last_insert_rowid()}))
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

fn task_links(c: &Connection, demo: bool, project: Option<i64>) -> Result<HashMap<i64, Vec<i64>>> {
    let mut links = HashMap::<i64, Vec<i64>>::new();
    let mut statement = c.prepare(
        "SELECT l.task_id,l.related_task_id FROM task_links l JOIN tasks a ON a.id=l.task_id
         JOIN tasks b ON b.id=l.related_task_id WHERE a.is_demo=?1 AND b.is_demo=?1
         AND (?2 IS NULL OR (json_extract(a.data_json,'$.project_id')=?2 AND json_extract(b.data_json,'$.project_id')=?2))
         ORDER BY l.task_id,l.related_task_id",
    )?;
    for relation in statement.query_map(params![demo,project], |row| Ok((row.get::<_,i64>(0)?,row.get::<_,i64>(1)?)))? {
        let (task, related) = relation?;
        links.entry(task).or_default().push(related);
        links.entry(related).or_default().push(task);
    }
    for related in links.values_mut() {
        related.sort_unstable();
        related.dedup();
    }
    Ok(links)
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
    pub(crate) fn analysis_project_context(&self, project_id: i64) -> Result<(Vec<Value>, Vec<Value>)> {
        let project = entity(&self.0, "projects", project_id)?;
        same_scope(&project, false)?;
        let mut statement = self.0.prepare(
            "SELECT id,data_json,revision,is_demo,created_at,updated_at FROM tasks
             WHERE is_demo=0 AND json_extract(data_json,'$.project_id')=?1",
        )?;
        let tasks = statement.query_map([project_id], decode_entity)?;
        let mut links = task_links(&self.0, false, Some(project_id))?;
        let stages: HashMap<_, _> = project["stages"].as_array().into_iter().flatten()
            .filter_map(|stage| stage["id"].as_str().map(|id| (id, stage))).collect();
        let mut annotated = Vec::new();
        for task in tasks {
            let mut task = task?;
            if let Some(related) = id(&task,"id").and_then(|id| links.remove(&id)) {
                task["related_task_ids"] = json!(related);
            }
            if let Some(stage) = task["stage_id"].as_str().and_then(|id| stages.get(id)) {
                task["stage_title"] = stage["title"].clone();
                task["stage_kind"] = stage["kind"].clone();
            }
            annotated.push(task);
        }
        let mut statement = self.0.prepare(
            "SELECT dt.task_id,d.text FROM decisions d JOIN decision_tasks dt ON dt.decision_id=d.id
             LEFT JOIN decision_context dc ON dc.decision_id=d.id
             WHERE d.project_id=?1 AND d.is_demo=0 AND coalesce(dc.status,'approved')='approved'
             ORDER BY d.id DESC, dt.task_id",
        )?;
        let decisions = statement.query_map([project_id], |row| Ok(json!({
            "task_id":row.get::<_,i64>(0)?, "text":row.get::<_,String>(1)?
        })))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok((annotated, decisions))
    }

    pub fn workspace(&self, demo: bool, at: Option<DateTime<Utc>>) -> Result<Value> {
        let prefs = settings(&self.0)?;
        let now = at.unwrap_or_else(Utc::now);
        let tz: Tz = text(&prefs, "timezone")
            .parse()
            .context("Неизвестный часовой пояс")?;
        let mut tasks = entities(&self.0, "tasks", demo)?;
        let mut links = task_links(&self.0, demo, None)?;
        let mut projects = entities(&self.0, "projects", demo)?;
        let default_stages = default_stages();
        let stages_by_project: HashMap<_, _> = projects
            .iter()
            .filter_map(|project| id(project, "id").map(|key| (key, &project["stages"])))
            .collect();
        let mut task_counts = HashMap::<i64, TaskCounts>::new();
        for task in &mut tasks {
            if let Some(related) = id(task,"id").and_then(|id| links.remove(&id)) {
                task["related_task_ids"] = json!(related);
            }
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
        let mut stmt=self.0.prepare("SELECT m.id,m.title,m.status,m.created_at,m.project_id,m.scheduled_at,
            (SELECT min(created_at) FROM capture_sources WHERE meeting_id=m.id),
            json_extract(p.data_json,'$.title') FROM meetings m LEFT JOIN projects p ON p.id=m.project_id
            WHERE m.is_demo=?1 ORDER BY m.id DESC")?;
        let rows=stmt.query_map([demo],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"title":r.get::<_,String>(1)?,"status":r.get::<_,String>(2)?,"created_at":r.get::<_,String>(3)?,"project_id":r.get::<_,Option<i64>>(4)?,"scheduled_at":r.get::<_,Option<String>>(5)?,"recorded_at":r.get::<_,Option<String>>(6)?,"project_name":r.get::<_,Option<String>>(7)?,"is_demo":demo})))?;
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
            let analysis = self.groq_analysis(mid)?;
            crate::groq::decorate_meeting_protocol(&mut m, &analysis, tz);
            m["analysis"] = analysis;
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
            if status == "pending" {
                if let Some(task_id) = crate::groq::suggested_task_refinement(&p, &tasks) {
                    p["suggested_existing_task_id"] = json!(task_id);
                }
            }
            proposals.push(p);
        }
        let mut stmt = self.0.prepare(
            "SELECT d.id,d.project_id,d.meeting_id,d.text,d.source_json,
                    coalesce(dc.status,'approved'),dc.approved_at,dc.reviewer_id,dc.reason,dc.supersedes_id,
                    (SELECT json_group_array(dt.task_id) FROM decision_tasks dt WHERE dt.decision_id=d.id)
             FROM decisions d LEFT JOIN decision_context dc ON dc.decision_id=d.id
             WHERE d.is_demo=?1 ORDER BY d.id DESC",
        )?;
        let mut decision_rows = stmt.query([demo])?;
        let mut decisions = Vec::new();
        while let Some(row) = decision_rows.next()? {
            decisions.push(json!({
                "id":row.get::<_,i64>(0)?,"project_id":row.get::<_,Option<i64>>(1)?,
                "meeting_id":row.get::<_,Option<i64>>(2)?,"text":row.get::<_,String>(3)?,
                "source":serde_json::from_str::<Value>(&row.get::<_,String>(4)?)?,
                "status":row.get::<_,String>(5)?,"approved_at":row.get::<_,Option<String>>(6)?,
                "reviewer_id":row.get::<_,Option<i64>>(7)?,"reason":row.get::<_,Option<String>>(8)?,
                "supersedes_id":row.get::<_,Option<i64>>(9)?,
                "task_ids":serde_json::from_str::<Value>(&row.get::<_,String>(10)?)?
            }));
        }
        let mut inbox = self.0.prepare(
            "SELECT n.id,n.task_id,n.decision_id,n.payload_json,n.created_at,n.read_at
             FROM task_notifications n JOIN tasks t ON t.id=n.task_id
             WHERE n.recipient_id=?1 AND t.is_demo=?2
             ORDER BY n.read_at IS NULL DESC,n.id DESC LIMIT 40",
        )?;
        let mut rows = inbox.query(params![id(&prefs, if demo {"demo_me_id"} else {"me_id"}),demo])?;
        let mut notifications = Vec::new();
        while let Some(row) = rows.next()? {
            notifications.push(json!({
                "id":row.get::<_,i64>(0)?,"task_id":row.get::<_,i64>(1)?,
                "decision_id":row.get::<_,Option<i64>>(2)?,
                "payload":serde_json::from_str::<Value>(&row.get::<_,String>(3)?)?,
                "created_at":row.get::<_,String>(4)?,"read_at":row.get::<_,Option<String>>(5)?
            }));
        }
        Ok(json!({"schema_version":1,"mode":if demo {"demo"}else{"real"},"now":now.to_rfc3339(),
            "today":now.with_timezone(&tz).date_naive().to_string(),"settings":prefs,"default_stages":default_stages,
            "people":people,"projects":projects,"tasks":tasks,"meetings":meetings,"proposals":proposals,
            "decisions":decisions,"notifications":notifications}))
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
            "read_task_notification" => {
                let me = id(&settings(&tx)?, if demo { "demo_me_id" } else { "me_id" });
                let changed = tx.execute(
                    "UPDATE task_notifications SET read_at=coalesce(read_at,strftime('%Y-%m-%dT%H:%M:%fZ','now'))
                     WHERE id=?1 AND recipient_id=?2 AND EXISTS
                       (SELECT 1 FROM tasks WHERE tasks.id=task_notifications.task_id AND is_demo=?3)",
                    params![id(body,"id"),me,demo],
                )?;
                if changed == 0 { bail!("Уведомление недоступно"); }
                json!({"read":true})
            }
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
                json!({"id":save_decision(&tx, Some(project_id), decision, &Value::Null, body, demo)?})
            }
            "cancel_decision" => {
                let decision_id = id(body, "id").context("Выберите решение")?;
                close_decision(&tx, decision_id, None, demo, "cancelled")?;
                json!({"cancelled":true})
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
            "assistant_command" => propose_assistant_command(&tx, body, demo)?,
            "propose" => {
                let p = &body["data"];
                if p["source"]["type"] == "assistant_command" { bail!("Используйте команду Валли"); }
                validate_source(&tx, &p["source"], demo)?;
                if ![
                    "create_task",
                    "change_due",
                    "change_assignee",
                    "change_status",
                    "change_blocked",
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
            "save_review_draft" => {
                let proposal_id = id(body, "id").context("Предложение не выбрано")?;
                let draft = body["draft"].as_object().context("Нет черновика")?;
                if !body["draft"]["data"].is_object() || body["draft"].to_string().len() > 64 * 1024
                    || id(&body["draft"], "id") != Some(proposal_id) || draft.contains_key("reject")
                {
                    bail!("Некорректный черновик предложения");
                }
                let changed = tx.execute(
                    "UPDATE proposals SET data_json=json_set(data_json,'$.review_draft',json(?2)) WHERE id=?1 AND is_demo=?3 AND status='pending'",
                    params![proposal_id, body["draft"].to_string(), demo],
                )?;
                if changed != 1 { bail!("Предложение уже рассмотрено или недоступно"); }
                json!({"saved":true})
            }
            "review" => {
                let result = review(&tx, body, demo, None)?;
                notify_decision_only(&tx, body, &result)?;
                result
            }
            "review_batch" => {
                let items = body["items"].as_array().context("Выберите предложения")?;
                if items.is_empty() || items.len() > 100 {
                    bail!("Выберите от одного до ста предложений");
                }
                let mut ordered: Vec<_> = items.iter().collect();
                let mut decision_id = None;
                let associate = body["associate_decision"] == true;
                if associate {
                    let mut decisions = Vec::new();
                    for (index, item) in items.iter().enumerate() {
                        let kind: String = tx.query_row(
                            "SELECT json_extract(data_json,'$.kind') FROM proposals WHERE id=?1 AND is_demo=?2",
                            params![id(item, "id"),demo], |row| row.get(0),
                        ).context("Предложение для пакета не найдено")?;
                        if kind == "decision" { decisions.push(index); }
                        if item["reject"] == true { bail!("Уберите отклонённое предложение из пакета"); }
                    }
                    if decisions.len() != 1 || items.len() < 2 {
                        bail!("Выберите одно решение и хотя бы одно связанное изменение");
                    }
                    let decision = ordered.remove(decisions[0]);
                    ordered.insert(0, decision);
                }
                let mut results = Vec::with_capacity(items.len());
                let mut notifications = std::collections::BTreeMap::new();
                let mut revisions = std::collections::HashMap::<i64, (i64, i64)>::new();
                for (index, item) in ordered.into_iter().enumerate() {
                    let mut request = item.clone();
                    let task = id(item, "existing_task_id");
                    let expected = id(item, "task_revision");
                    if let (Some(task), Some(expected)) = (task, expected) {
                        if let Some(&(initial, current)) = revisions.get(&task) {
                            if expected == initial {
                                request["task_revision"] = json!(current);
                            } else {
                                bail!("У предложений для одной задачи разные версии. Проверьте пакет заново");
                            }
                        } else if entity(&tx, "tasks", task)?["revision"] != json!(expected) {
                            bail!("Задача изменилась после открытия предложения. Проверьте новые значения");
                        }
                    }
                    let result = review(&tx, &request, demo, decision_id)
                        .map_err(|error| anyhow::anyhow!("Предложение №{}: {error}", item["id"]))?;
                    if !associate { notify_decision_only(&tx, item, &result)?; }
                    if associate && index == 0 {
                        decision_id = Some(id(&result, "decision_id").context("Решение не сохранено")?);
                    }
                    if associate && result["task_changed"] == true {
                        if let Some(task_id) = id(&result["task"],"id") {
                            notifications.insert(task_id, (id(item,"id").unwrap(), result["task"].clone(),result["source"].clone()));
                        }
                    }
                    if let (Some(task), Some(expected), Some(current)) =
                        (task, expected, id(&result["task"], "revision"))
                    {
                        if id(&result["task"], "id") == Some(task) {
                            revisions.entry(task)
                                .and_modify(|entry| entry.1 = current)
                                .or_insert((expected, current));
                        }
                    }
                    results.push(result);
                }
                for (_, (proposal_id,task,source)) in notifications {
                    notify_task_change(&tx, proposal_id, decision_id, &task, "decision", &source)?;
                }
                json!({"applied":results})
            }
            _ => bail!("Неизвестная команда рабочего пространства"),
        };
        tx.commit()?;
        Ok(result)
    }
    pub fn auto_process_enabled(&self) -> Result<bool> {
        Ok(settings(&self.0)?["auto_process"] == true)
    }
}
pub(crate) fn change_fields(kind: &str) -> &'static [&'static str] {
    match kind {
        "change_task" => &["due_date", "due_time", "assignee_id"],
        "change_due" => &["due_date", "due_time"],
        "change_assignee" => &["assignee_id"],
        "change_status" => &["stage_id"],
        "change_blocked" => &["blocked", "blocked_reason"],
        _ => &[],
    }
}

fn close_decision(c: &Connection, decision: i64, project: Option<i64>, demo: bool, status: &str) -> Result<()> {
    let (scope, existing_project): (bool, Option<i64>) = c.query_row(
        "SELECT is_demo,project_id FROM decisions WHERE id=?1", [decision],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).context("Решение не найдено")?;
    if scope != demo || (project.is_some() && project != existing_project) {
        bail!("Выберите решение из того же проекта");
    }
    let changed = c.execute(
        "INSERT INTO decision_context(decision_id,status,approved_at) VALUES (?1,?2,NULL)
         ON CONFLICT(decision_id) DO UPDATE SET status=excluded.status WHERE decision_context.status='approved'",
        params![decision,status],
    )?;
    if changed == 0 {
        bail!("Решение уже отменено или заменено");
    }
    Ok(())
}

fn link_decision_task(c: &Connection, decision: i64, task: i64, project: Option<i64>, demo: bool) -> Result<()> {
    let current = entity(c, "tasks", task)?;
    same_scope(&current, demo)?;
    if id(&current, "project_id") != project {
        bail!("Свяжите решение с задачей из того же проекта");
    }
    c.execute("INSERT OR IGNORE INTO decision_tasks(decision_id,task_id) VALUES (?1,?2)", params![decision,task])?;
    Ok(())
}

fn save_decision(c: &Connection, project: Option<i64>, decision: &str, source: &Value,
                 details: &Value, demo: bool) -> Result<i64> {
    let reason = text(details, "reason").trim();
    if decision.len() > 24_000 || reason.len() > 12_000 {
        bail!("Текст решения или обоснования слишком длинный");
    }
    let supersedes = id(details, "supersedes_id");
    if let Some(prior) = supersedes {
        let project = project.context("Чтобы заменить решение, выберите проект")?;
        close_decision(c, prior, Some(project), demo, "superseded")?;
    }
    c.execute(
        "INSERT INTO decisions(project_id,meeting_id,text,source_json,is_demo) VALUES (?1,?2,?3,?4,?5)",
        params![project,id(source,"meeting_id"),decision,source.to_string(),demo],
    )?;
    let decision_id = c.last_insert_rowid();
    let me = id(&settings(c)?, if demo { "demo_me_id" } else { "me_id" });
    c.execute("INSERT INTO decision_context(decision_id,reviewer_id,reason,supersedes_id) VALUES (?1,?2,?3,?4)",
        params![decision_id,me,(!reason.is_empty()).then_some(reason),supersedes])?;
    if let Some(task_id) = id(source, "task_id") {
        link_decision_task(c, decision_id, task_id, project, demo)?;
    }
    if let Some(task_ids) = details.get("task_ids") {
        let task_ids = task_ids.as_array().filter(|items| items.len() <= 100).context("Некорректный список задач решения")?;
        for task in task_ids {
            link_decision_task(c, decision_id, task.as_i64().context("Некорректный идентификатор задачи")?, project, demo)?;
        }
    }
    Ok(decision_id)
}

fn notify_task_change(c: &Connection, proposal_id: i64, decision_id: Option<i64>,
                      task: &Value, kind: &str, source: &Value) -> Result<()> {
    let (Some(task_id), Some(recipient)) = (id(task, "id"), id(task, "assignee_id")) else {
        return Ok(());
    };
    let event_key = decision_id.map_or_else(|| format!("proposal:{proposal_id}"), |id| format!("decision:{id}"));
    let payload = json!({"kind":kind,"title":task["title"],"project_id":task["project_id"],
        "due_date":task["due_date"],"due_time":task["due_time"],"stage_id":task["stage_id"],
        "blocked":task["blocked"],"source":source});
    c.execute(
        "INSERT INTO task_notifications(event_key,task_id,recipient_id,proposal_id,decision_id,payload_json)
         VALUES (?1,?2,?3,?4,?5,?6)
         ON CONFLICT(event_key,task_id,recipient_id) DO UPDATE SET payload_json=excluded.payload_json",
        params![event_key,task_id,recipient,proposal_id,decision_id,payload.to_string()],
    )?;
    Ok(())
}

fn notify_decision_only(c: &Connection, request: &Value, result: &Value) -> Result<()> {
    let (Some(proposal), Some(decision)) = (id(request,"id"), id(result,"decision_id")) else {
        return Ok(());
    };
    if !result["task"].is_null() { return Ok(()); }
    let mut statement = c.prepare("SELECT task_id FROM decision_tasks WHERE decision_id=?1 ORDER BY task_id")?;
    let tasks = statement.query_map([decision], |row| row.get::<_,i64>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for task_id in tasks {
        let task = entity(c,"tasks",task_id)?;
        notify_task_change(c,proposal,Some(decision),&task,"decision",&result["source"])?;
    }
    Ok(())
}

fn review(c: &Connection, body: &Value, demo: bool, linked_decision: Option<i64>) -> Result<Value> {
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
    let mut evidence = proposal["source"].clone();
    let linked_project = if let Some(decision) = linked_decision {
        let (project, meeting): (Option<i64>, Option<i64>) = c.query_row(
            "SELECT project_id,meeting_id FROM decisions WHERE id=?1 AND is_demo=?2",
            params![decision,demo], |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if meeting != id(&evidence, "meeting_id") {
            bail!("Решение и предложения должны относиться к одной встрече");
        }
        evidence["decision_id"] = json!(decision);
        project
    } else { None };
    let source = &evidence;
    // Proposals retain the quoted evidence from the analysis that created them.
    validate_source(c, source, demo)?;
    let approved = &body["data"];
    let mut result = Value::Null;
    let mut applied_decision_id = linked_decision;
    let kind = text(&proposal, "kind");
    let mut task_changed = false;
    if proposal["project_required"] == true && id(approved, "project_id").is_none()
        && (kind == "decision" || (kind == "create_task" && id(body, "existing_task_id").is_none())) {
        bail!("Выберите проект для этого пункта встречи");
    }
    match kind {
        "decision" => {
            let decision = text(approved, "title").trim();
            if decision.is_empty() {
                bail!("Укажите решение");
            }
            let project = id(approved, "project_id");
            if let Some(p) = project {
                same_scope(&entity(c, "projects", p)?, demo)?;
            }
            let mut details = approved.clone();
            if details.get("task_ids").is_none() && project == id(&proposal,"project_id")
                && proposal["decision_task_ids"].is_array() {
                details["task_ids"] = proposal["decision_task_ids"].clone();
            }
            applied_decision_id = Some(save_decision(c, project, decision, source, &details, demo)?);
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
                let apply_description = body["apply_description"] == true;
                if (body["apply_due"] == true || body["apply_assignee"] == true || apply_description)
                    && body["task_revision"] != old["revision"] {
                    bail!("Задача изменилась. Откройте предложение заново");
                }
                if apply_description {
                    if proposal["project_id"] != old["project_id"] {
                        bail!("Уточнение должно относиться к тому же проекту");
                    }
                    let detail = text(approved, "description").trim();
                    let previous = text(&old, "description").trim_end();
                    if !detail.is_empty() && !previous.split("\n\n").any(|part| part.trim() == detail) {
                        data["description"] = json!(if previous.is_empty() { detail.to_owned() }
                            else { format!("{previous}\n\n{detail}") });
                    }
                }
                if body["apply_assignee"] == true {
                    data["assignee_id"] = json!(id(approved, "assignee_id").context("Выберите исполнителя")?);
                }
                if body["apply_due"] == true {
                    data["due_date"] = approved["due_date"].clone();
                    data["due_time"] = approved["due_time"].clone();
                }
                if body["apply_due"] == true || body["apply_assignee"] == true || apply_description {
                    validate_task(c, &mut data, demo, Some(existing))?;
                    task_changed = ["assignee_id", "due_date", "due_time", "description"]
                        .iter().any(|key| data[*key] != old[*key]);
                }
                result = save(c, "tasks", data, Some(&old), demo, None)?;
            } else {
                if matches!(text(&proposal,"origin"), "groq" | "assistant_command") && body["confirm_separate_task"] != true {
                    let project = id(approved, "project_id");
                    let title = text(approved, "title");
                    let candidates = proposal["candidate_task_ids"].as_array();
                    let matching = entities(c, "tasks", demo)?.iter().any(|task| {
                        id(task, "project_id") == project
                            && (crate::groq::same_action_title(text(task, "title"), title)
                                || candidates.is_some_and(|ids| ids.contains(&task["id"])))
                    });
                    if matching {
                        bail!("Есть похожая задача. Выберите её или подтвердите создание отдельной");
                    }
                }
                let mut data = approved.clone();
                let related = approved.get("related_task_id").unwrap_or(&proposal["related_task_id"]);
                let related_task = if related.is_null() { None } else {
                    let task_id = related.as_i64().context("Некорректная связанная задача")?;
                    let related = entity(c, "tasks", task_id)?;
                    same_scope(&related, demo)?;
                    if id(&related, "project_id") != id(approved, "project_id") {
                        bail!("Связанная задача должна относиться к выбранному проекту");
                    }
                    Some(task_id)
                };
                data.as_object_mut().context("Нужны поля задачи")?.remove("related_task_id");
                let mut sources = vec![source.clone()];
                let mut merged = std::collections::HashSet::new();
                if let Some(related) = body.get("related_proposal_ids") {
                    let related = related.as_array().context("Некорректный список связанных предложений")?;
                    if related.len() > 30 { bail!("Слишком много связанных предложений"); }
                    for related_id in related {
                        let related_id = related_id.as_i64().context("Некорректный идентификатор предложения")?;
                        if related_id == pid { bail!("Предложение уже выбрано как основное"); }
                        let (raw, status, scope): (String, String, bool) = c.query_row(
                            "SELECT data_json,status,is_demo FROM proposals WHERE id=?1",
                            [related_id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                        )?;
                        let item: Value = serde_json::from_str(&raw)?;
                        let evidence = &item["source"];
                        if scope != demo || id(evidence, "meeting_id") != id(source, "meeting_id")
                            || id(&item, "project_id") != id(approved, "project_id") {
                            bail!("Связанные пункты должны относиться к одной встрече и проекту");
                        }
                        match (text(&item, "kind"), status.as_str()) {
                            ("decision", "accepted") => {}
                            ("create_task" | "change_due" | "change_assignee", "pending") => {
                                if !item["task_id"].is_null() {
                                    bail!("Связанное предложение уже относится к существующей задаче");
                                }
                                merged.insert(related_id);
                            }
                            _ => bail!("Связанное предложение уже рассмотрено или недоступно"),
                        }
                        validate_source(c, evidence, demo)?;
                        if !sources.contains(evidence) { sources.push(evidence.clone()); }
                    }
                }
                data["sources"] = json!(sources);
                result = task_save(c, &json!({"data":data}), demo, None)?;
                task_changed = true;
                if let Some(related) = related_task {
                    c.execute("INSERT INTO task_links(task_id,related_task_id,source_json) VALUES (?1,?2,?3)",
                        params![id(&result,"id"), related, source.to_string()])?;
                }
                for related_id in merged {
                    c.execute(
                        "UPDATE proposals SET status='accepted',data_json=json_remove(
                            json_set(data_json,'$.confirmed_task_id',?2),'$.review_draft') WHERE id=?1",
                        params![related_id, id(&result, "id")],
                    )?;
                }
            }
        }
        kind @ ("change_task" | "change_due" | "change_assignee" | "change_status" | "change_blocked") => {
            let tid = id(body, "existing_task_id")
                .or_else(|| id(&proposal, "task_id"))
                .context("Выберите существующую задачу")?;
            let old = entity(c, "tasks", tid)?;
            same_scope(&old, demo)?;
            if proposal["origin"] == "assistant_command" && proposal["project_id"] != old["project_id"] {
                bail!("Задача теперь в другом проекте. Отправьте команду заново");
            }
            if matches!(text(&proposal,"origin"),"groq" | "local_analysis")
                && id(&proposal,"task_id") == Some(tid) && !proposal["project_id"].is_null()
                && id(&proposal,"project_id") != id(&old,"project_id") {
                bail!("Задачу перенесли в другой проект. Выберите её заново после повторного анализа");
            }
            if body["task_revision"] != old["revision"] {
                bail!("Задача изменилась после открытия предложения. Проверьте новые значения");
            }
            let fields = change_fields(kind);
            let baseline = if id(&proposal, "task_id") == Some(tid) {
                proposal.get("base_task")
            } else {
                proposal["candidate_baselines"].as_array().into_iter().flatten()
                    .find(|candidate| id(candidate,"task_id") == Some(tid)).map(|candidate| &candidate["base"])
            };
            if body["acknowledge_task_conflict"] != true
                && baseline.is_some_and(|base| base.is_object() && fields.iter().any(|key| base[*key] != old[*key]))
            {
                bail!("Поля задачи изменились после анализа. Сверьте текущие значения и подтвердите замену");
            }
            if kind == "change_task" {
                if old["project_id"] != proposal["project_id"] {
                    bail!("Выберите задачу из проекта предложения");
                }
                let project = id(&old, "project_id").map(|id| entity(c, "projects", id)).transpose()?;
                if project.is_none() && proposal["origin"] != "assistant_command" { bail!("Задача без проекта"); }
                if project.is_some_and(|project| project["archived"] == true)
                    || !stages(c, &old, demo)?.as_array().into_iter().flatten()
                    .any(|stage| stage["id"] == old["stage_id"] && stage["kind"] == "active") {
                    bail!("Пакет можно применить только к активной задаче проекта");
                }
                if text(approved, "due_date").is_empty() || id(approved, "assignee_id").is_none() {
                    bail!("Укажите срок и исполнителя для пакета изменений");
                }
            }
            let mut data = old.clone();
            for key in fields {
                data[*key] = approved[*key].clone();
            }
            validate_task(c, &mut data, demo, Some(tid))?;
            task_changed = fields.iter().any(|key| data[*key] != old[*key]);
            let mut sources = data["sources"].as_array().cloned().unwrap_or_default();
            let mut evidence = source.clone();
            evidence["proposal_id"] = json!(pid);
            evidence["task_id"] = json!(tid);
            if kind == "change_task" {
                if ["due_date", "due_time", "assignee_id"].iter().all(|key| data[*key] == old[*key]) {
                    bail!("Этот срок и исполнитель уже установлены");
                }
                let person: String = c.query_row("SELECT name FROM people WHERE id=?1", [id(&data, "assignee_id")], |r| r.get(0))?;
                let deadline = [data["due_date"].as_str(), data["due_time"].as_str()]
                    .into_iter().flatten().collect::<Vec<_>>().join(" ");
                let decision = format!("{} · срок {} · исполнитель {}", text(&old, "title"), deadline, person);
                if applied_decision_id.is_none() {
                    applied_decision_id = Some(save_decision(c, id(&old, "project_id"), &decision, &evidence, &Value::Null, demo)?);
                }
                evidence["decision_id"] = json!(applied_decision_id);
            }
            if !sources.contains(&evidence) { sources.push(evidence); }
            data["sources"] = json!(sources);
            result = save(c, "tasks", data, Some(&old), demo, None)?;
        }
        _ => bail!("Неизвестный тип предложения"),
    }
    if let Some(decision) = linked_decision {
        link_decision_task(c, decision, id(&result, "id").context("Выберите предложение по задаче")?, linked_project, demo)?;
    }
    if task_changed && linked_decision.is_none() {
        notify_task_change(c, pid, applied_decision_id, &result, kind, source)?;
    }
    let mut saved = proposal.clone();
    saved.as_object_mut().context("Некорректное предложение")?.remove("review_draft");
    saved["confirmed_task_id"] = result["id"].clone();
    let fields = change_fields(text(&proposal, "kind"));
    if !fields.is_empty() {
        saved["applied"] = Value::Object(fields.iter().map(|key| (key.to_string(), result[*key].clone())).collect());
    }
    if let Some(decision_id) = applied_decision_id {
        saved["decision_id"] = json!(decision_id);
    }
    c.execute(
        "UPDATE proposals SET status='accepted',data_json=?2 WHERE id=?1",
        params![pid, saved.to_string()],
    )?;
    Ok(json!({"accepted":true,"task":result,"decision_id":applied_decision_id,
        "task_changed":task_changed,"source":source}))
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
