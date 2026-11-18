use chrono::{Datelike, Days, NaiveDate};
use serde_json::{json, Value};

pub(crate) const MODEL: &str = "local:rules";

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

fn command(text: &str) -> Option<(i64, &str)> {
    let (target, command) = text.split_once(':')?;
    let target = target.strip_prefix("по задаче #").or_else(|| target.strip_prefix("задача #"))?;
    Some((target.trim().parse().ok()?, command.trim()))
}

pub(crate) fn analyze(input: &Value) -> Value {
    let date = input["created_at"].as_str().and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok());
    let timezone = input["timezone"].as_str().and_then(|value| value.parse::<chrono_tz::Tz>().ok());
    let today = date.zip(timezone).map(|(date, tz)| date.with_timezone(&tz).date_naive());
    let mut proposals = Vec::new();
    for segment in input["segments"].as_array().into_iter().flatten() {
        let Some(text) = segment["text"].as_str() else { continue; };
        let normalized = text.to_lowercase().replace('ё', "е");
        let Some((id, action)) = command(normalized.trim()) else { continue; };
        let Some(task) = input["project_tasks"].as_array().into_iter().flatten().find(|task| task["id"] == id) else { continue; };
        let mut proposal = json!({"title":task["title"],"task_id":id,"description":"",
            "source_segment_ids":[segment["id"]],"needs_clarification":false});
        if let Some(date) = action.strip_prefix("перенести срок на ").or_else(|| action.strip_prefix("срок до ")) {
            let Some(date) = today.and_then(|today| parse_date(date, today)) else { continue; };
            proposal["kind"] = json!("change_due");
            proposal["due_date"] = json!(date.format("%Y-%m-%d").to_string());
        } else if action.trim_end_matches(['.', '!']) == "снять блокировку" {
            proposal["kind"] = json!("change_blocked");
            proposal["blocked"] = json!(false);
        } else if let Some(name) = action.strip_prefix("назначить ") {
            let name = name.trim_end_matches(['.', '!']).trim();
            if name.is_empty() || name.chars().count() > 120 { continue; }
            proposal["kind"] = json!("change_assignee");
            proposal["assignee_name"] = json!(name);
        } else if let Some(stage) = action.strip_prefix("статус ") {
            let stage = stage.trim_end_matches(['.', '!']).trim();
            if stage.is_empty() || stage.chars().count() > 120 { continue; }
            proposal["kind"] = json!("change_status");
            proposal["stage_title"] = json!(stage);
        } else if action.starts_with("заблокировать:") {
            let reason = text.splitn(3, ':').nth(2).unwrap_or_default().trim();
            if reason.is_empty() || reason.chars().count() > 2000 { continue; }
            proposal["kind"] = json!("change_blocked");
            proposal["blocked"] = json!(true);
            proposal["blocked_reason"] = json!(reason);
        } else {
            continue;
        }
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
