use chrono::{Datelike, Days, NaiveDate, NaiveTime};
use serde_json::{json, Value};

pub(crate) const MODEL: &str = "local:rules-v3";

fn parse_date(text: &str, today: NaiveDate) -> Option<NaiveDate> {
    let text = text.trim_end_matches(['.', '!', ';']).trim();
    match text {
        "сегодня" => return Some(today),
        "завтра" => return today.checked_add_days(Days::new(1)),
        "послезавтра" => return today.checked_add_days(Days::new(2)),
        _ => {}
    }
    if let Ok(date) = NaiveDate::parse_from_str(text, "%Y-%m-%d") {
        return Some(date);
    }
    let mut words = text.split_whitespace();
    let day = words.next()?.parse::<u32>().ok()?;
    let month = [
        "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа",
        "сентября", "октября", "ноября", "декабря",
    ];
    let month_name = words.next()?;
    let month = month.iter().position(|month| *month == month_name)? as u32 + 1;
    let year = match words.next() {
        Some(year) => Some(year.parse::<i32>().ok()?),
        None => None,
    };
    if words.next().is_some() { return None; }
    let date = NaiveDate::from_ymd_opt(year.unwrap_or(today.year()), month, day)?;
    if year.is_none() && date < today {
        // A past-looking date without a year can refer to either year.
        return None;
    }
    Some(date)
}

fn parse_deadline(text: &str, today: NaiveDate) -> Option<(NaiveDate, Option<NaiveTime>)> {
    let text = text.trim_end_matches(['.', '!', ';']).trim();
    if let Some((date, time)) = text.rsplit_once(char::is_whitespace).filter(|(_, time)| time.contains(':')) {
        let date = date.trim_end();
        let date = date.strip_suffix(" в").or_else(|| date.strip_suffix(" к")).unwrap_or(date);
        return Some((parse_date(date, today)?, Some(NaiveTime::parse_from_str(time, "%H:%M").ok()?)));
    }
    Some((parse_date(text, today)?, None))
}

pub(crate) fn parse_command(text: &str, today: Option<NaiveDate>) -> Option<(i64, Value)> {
    let (target, action) = text.trim().split_once(':')?;
    let target = target.to_lowercase();
    let id: i64 = target.strip_prefix("по задаче #").or_else(|| target.strip_prefix("задача #"))?
        .trim().parse().ok()?;
    let mut proposal = parse_action(action, today)?;
    if proposal["kind"] == "create_task" {
        proposal["related_task_id"] = json!(id);
    }
    Some((id, proposal))
}

pub(crate) fn parse_action(text: &str, today: Option<NaiveDate>) -> Option<Value> {
    let normalized = text.to_lowercase().replace('ё', "е");
    let action = normalized.trim();
    let mut proposal = json!({});
    if let Some(date) = ["перенести срок на ", "перенеси срок на ", "поставь срок на ", "срок до "]
        .iter().find_map(|prefix| action.strip_prefix(*prefix)) {
        return deadline_action(date, today?);
    } else if action.trim_end_matches(['.', '!']) == "снять блокировку" {
        proposal["kind"] = json!("change_blocked");
        proposal["blocked"] = json!(false);
    } else if let Some(name) = action.strip_prefix("назначить ") {
        let name = name.trim_end_matches(['.', '!']).trim();
        if name.is_empty() || name.chars().count() > 120 { return None; }
        proposal["kind"] = json!("change_assignee");
        proposal["assignee_name"] = json!(name);
    } else if let Some(stage) = action.strip_prefix("статус ") {
        let stage = stage.trim_end_matches(['.', '!']).trim();
        if stage.is_empty() || stage.chars().count() > 120 { return None; }
        proposal["kind"] = json!("change_status");
        proposal["stage_title"] = json!(stage);
    } else if action.starts_with("заблокировать:") {
        let reason = text.split_once(':')?.1.trim();
        if reason.is_empty() || reason.chars().count() > 2000 { return None; }
        proposal["kind"] = json!("change_blocked");
        proposal["blocked"] = json!(true);
        proposal["blocked_reason"] = json!(reason);
    } else if action.starts_with("создать связанную задачу:") {
        let title = text.split_once(':')?.1.trim();
        if title.is_empty() || title.chars().count() > 500 { return None; }
        proposal["kind"] = json!("create_task");
        proposal["title"] = json!(title);
    } else {
        return None;
    }
    Some(proposal)
}

fn deadline_action(text: &str, today: NaiveDate) -> Option<Value> {
    let text = text.trim_end_matches(['.', '!', ';', '?']).trim();
    let (date, time, assignee) = if let Some((date, time)) = parse_deadline(text, today) {
        (date, time, None)
    } else {
        let (deadline, assignee) = text.rsplit_once(char::is_whitespace)?;
        if !assignee.chars().all(|c| c.is_alphabetic() || c == '-') { return None; }
        let (date, time) = parse_deadline(deadline.trim_end_matches(',').trim_end(), today)?;
        (date, time, Some(assignee))
    };
    Some(json!({
        "kind": if assignee.is_some() { "change_task" } else { "change_due" },
        "due_date": date.format("%Y-%m-%d").to_string(),
        "due_time": time.map(|time| time.format("%H:%M").to_string()),
        "assignee_name": assignee,
    }))
}

pub(crate) fn analyze(input: &Value) -> Value {
    let date = input["created_at"].as_str().and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok());
    let timezone = input["timezone"].as_str().and_then(|value| value.parse::<chrono_tz::Tz>().ok());
    let today = date.zip(timezone).map(|(date, tz)| date.with_timezone(&tz).date_naive());
    let mut proposals = Vec::new();
    for segment in input["segments"].as_array().into_iter().flatten() {
        let Some(text) = segment["text"].as_str() else { continue; };
        let Some((id, mut proposal)) = parse_command(text, today) else { continue; };
        let Some(task) = input["project_tasks"].as_array().into_iter().flatten().find(|task| task["id"] == id) else { continue; };
        if proposal["kind"] != "create_task" {
            proposal["title"] = task["title"].clone();
            proposal["task_id"] = json!(id);
        }
        proposal["description"] = json!("");
        proposal["source_segment_ids"] = json!([segment["id"]]);
        proposal["needs_clarification"] = json!(false);
        proposals.push(proposal);
        if proposals.len() >= 96 { break; }
    }
    let summary = if proposals.is_empty() {
        "В протоколе не найдено явных команд со ссылкой на ID задачи."
    } else {
        "Из протокола выделены явные изменения по указанным ID задач. Проверьте предложения перед применением."
    };
    json!({"summary":summary,"open_questions":[],"decisions":[],"tasks":proposals})
}
