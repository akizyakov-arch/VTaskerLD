//! Opt-in, text-only Groq analysis. Credentials never enter SQLite or public snapshots.
use crate::Store;
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::Path,
    process::{Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
};
pub const MODELS: [&str; 8] = [
    "openai/gpt-oss-120b", "openai/gpt-oss-20b",
    "deepseek:deepseek-flash", "deepseek:deepseek-v4-pro",
    "openai:gpt-4.1-mini", "gemini:gemini-2.5-flash",
    "mistral:mistral-small-latest", "anthropic:claude-sonnet-4-5",
];

fn provider(model: &str) -> &str {
    model.split_once(':').map(|(name, _)| name).unwrap_or("groq")
}

fn valid_model(model: &str) -> bool {
    MODELS.contains(&model) || model.split_once(':').is_some_and(|(name, id)| {
        ["deepseek", "openai", "gemini", "mistral", "anthropic"].contains(&name)
            && !id.is_empty() && id.len() <= 160
            && id.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_./".contains(&c))
    })
}

fn key_account(base: &str, model: &str) -> String {
    if provider(model) == "groq" { base.to_owned() }
    else { format!("{:x}", Sha256::digest(format!("{base}:{}", provider(model)).as_bytes())) }
}

pub fn revision(c: &Connection, mid: i64) -> Result<String> {
    let mut hash = Sha256::new();
    // A new extraction policy must not silently reuse an older empty result.
    hash.update(b"vtask-groq-context-tasks-v4");
    // Include corrections, confirmed names, participants, recording occurrences and workspace date context.
    for sql in [
        "SELECT * FROM meetings WHERE id=?1",
        "SELECT * FROM model_runs WHERE meeting_id=?1 ORDER BY id",
        "SELECT * FROM segment_edits WHERE model_run_id IN (SELECT id FROM model_runs WHERE meeting_id=?1) ORDER BY id",
        "SELECT * FROM segment_assignments WHERE model_run_id IN (SELECT id FROM model_runs WHERE meeting_id=?1) ORDER BY id",
        "SELECT * FROM speaker_assignments WHERE model_run_id IN (SELECT id FROM model_runs WHERE meeting_id=?1) ORDER BY id",
        "SELECT * FROM recordings WHERE meeting_id=?1 ORDER BY id",
        "SELECT * FROM capture_fragments WHERE meeting_id=?1 ORDER BY session_id,sequence",
        "SELECT * FROM people WHERE id IN (SELECT person_id FROM meeting_people WHERE meeting_id=?1 UNION SELECT person_id FROM segment_assignments WHERE model_run_id IN (SELECT id FROM model_runs WHERE meeting_id=?1) UNION SELECT person_id FROM speaker_assignments WHERE model_run_id IN (SELECT id FROM model_runs WHERE meeting_id=?1)) ORDER BY id",
        "SELECT * FROM meeting_people WHERE meeting_id=?1 ORDER BY person_id",
        "SELECT json_extract(data_json,'$.timezone') FROM workspace_settings WHERE key='preferences' AND ?1 IS NOT NULL",
    ] {
        hash.update(sql.as_bytes());
        let mut stmt=c.prepare(sql)?;let count=stmt.column_count();let mut rows=stmt.query([mid])?;
        while let Some(row)=rows.next()? {for i in 0..count {let v=format!("{:?}",row.get_ref(i)?);hash.update(v.len().to_le_bytes());hash.update(v.as_bytes());}}
    }
    Ok(format!("{:x}", hash.finalize()))
}
// A later run can split a compound поручение into its original actions.
fn same_action_title(first: &str, second: &str) -> bool {
    fn words(title: &str) -> std::collections::HashSet<String> {
        title
            .to_lowercase()
            .split(|ch: char| !ch.is_alphanumeric())
            .filter(|word| word.chars().count() >= 4)
            .map(|word| {
                if matches!(word, "помыть" | "вымыть" | "мыть") {
                    return "мыть".into();
                }
                word.to_owned()
            })
            .collect()
    }
    if first.trim().to_lowercase() == second.trim().to_lowercase() {
        return true;
    }
    let first = words(first);
    let second = words(second);
    second.len() >= 2 && second.is_subset(&first)
}

fn bounded(v: &Value, key: &str, limit: usize, required: bool) -> Result<String> {
    let text = v[key]
        .as_str()
        .context("Некорректный текст в ответе Groq")?
        .trim();
    if text.chars().count() > limit || (required && text.is_empty()) {
        bail!("Недопустимая длина текста Groq");
    }
    Ok(text.to_owned())
}
impl Store {
    pub fn groq_snapshot(&self, mid: i64) -> Result<Value> {
        let (title, date, project, demo, status): (String, String, Option<i64>, bool, String) =
            self.0.query_row(
                "SELECT title,created_at,project_id,is_demo,status FROM meetings WHERE id=?1",
                [mid],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )?;
        if demo {
            bail!("Groq недоступен для демонстрационных встреч");
        }
        if status == "recording" || status == "paused" {
            bail!("Завершите запись перед анализом");
        }
        let t = self.transcript(mid)?;
        let run = t["model_run_id"]
            .as_i64()
            .context("Сначала распознайте встречу")?;
        if t["parameters"]["demonstration"] == true {
            bail!("Демонстрационный транскрипт не отправляется в Groq");
        }
        let inputs: String = self.0.query_row(
            "SELECT inputs_json FROM model_runs WHERE id=?1",
            [run],
            |r| r.get(0),
        )?;
        if serde_json::from_str::<Value>(&inputs)?
            .as_array()
            .map_or(0, Vec::len)
            != self.audio_inputs(mid)?.len()
        {
            bail!("После продолжения встречи обновите распознавание");
        }
        let segments:Vec<Value>=t["segments"].as_array().context("Нет транскрипта")?.iter().filter(|s|!s["text"].as_str().unwrap_or("").trim().is_empty()).map(|s|json!({"id":s["id"],"start_ms":s["start_ms"],"end_ms":s["end_ms"],"text":s["text"],"person_name":s["person_name"],"person_id":s["person_id"]})).collect();
        if segments.is_empty() {
            bail!("Транскрипт пуст");
        }
        let mut stmt=self.0.prepare("SELECT p.id,p.name FROM people p JOIN meeting_people mp ON mp.person_id=p.id WHERE mp.meeting_id=?1 AND p.is_demo=0 ORDER BY p.id")?;
        let people = stmt
            .query_map([mid], |r| {
                Ok(json!({"id":r.get::<_,i64>(0)?,"name":r.get::<_,String>(1)?}))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let timezone = self.workspace_timezone()?;
        let value = json!({"meeting_id":mid,"title":title,"created_at":date,"timezone":timezone,"project_id":project,"model_run_id":run,"source_revision":revision(&self.0,mid)?,"participants":people,"segments":segments});
        if value.to_string().len() > 350_000 {
            bail!("Транскрипт слишком большой для одного анализа");
        }
        Ok(value)
    }
    fn workspace_timezone(&self) -> Result<String> {
        let raw: Option<String> = self
            .0
            .query_row(
                "SELECT data_json FROM workspace_settings WHERE key='preferences'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        Ok(raw
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .and_then(|v| v["timezone"].as_str().map(str::to_owned))
            .unwrap_or("Europe/Moscow".into()))
    }
    pub fn groq_analysis(&self, mid: i64) -> Result<Value> {
        let mut stmt=self.0.prepare("SELECT id,state,model,source_revision,result_json,error,created_at FROM meeting_analyses WHERE meeting_id=?1 ORDER BY id DESC")?;
        let rows=stmt.query_map([mid],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"state":r.get::<_,String>(1)?,"model":r.get::<_,String>(2)?,"source_revision":r.get::<_,String>(3)?,"result":r.get::<_,Option<String>>(4)?.and_then(|s|serde_json::from_str::<Value>(&s).ok()),"error":r.get::<_,Option<String>>(5)?,"created_at":r.get::<_,String>(6)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        if rows.is_empty() {
            return Ok(Value::Null);
        }
        let current = revision(&self.0, mid)?;
        let mut latest = rows[0].clone();
        latest["saved"] = rows
            .iter()
            .find(|r| r["state"] == "completed")
            .cloned()
            .unwrap_or(Value::Null);
        latest["stale"] =
            json!(!latest["saved"].is_null() && latest["saved"]["source_revision"] != current);
        Ok(latest)
    }
    pub fn groq_prepare(&self, mid: i64, model: &str, consent: bool) -> Result<(i64, Value, bool)> {
        if !consent {
            bail!("Подтвердите отправку текста в Groq");
        }
        if !valid_model(model) {
            bail!("Неизвестная модель Groq");
        }
        let input = self.groq_snapshot(mid)?;
        let tx = self.0.unchecked_transaction()?;
        if revision(&tx, mid)? != input["source_revision"].as_str().unwrap() {
            bail!("Встреча изменилась. Откройте анализ заново");
        }
        let existing:Option<(i64,String)>=tx.query_row("SELECT id,state FROM meeting_analyses WHERE meeting_id=?1 AND source_revision=?2 AND model=?3",params![mid,input["source_revision"].as_str(),model],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((id, state)) = existing {
            if state == "completed" {
                tx.commit()?;
                return Ok((id, input, true));
            }
            if state == "running" || state == "pending" {
                bail!("Анализ уже выполняется");
            }
            tx.execute("UPDATE meeting_analyses SET state='running',error=NULL,result_json=NULL,finished_at=NULL WHERE id=?1",[id])?;
            tx.commit()?;
            return Ok((id, input, false));
        }
        tx.execute("INSERT INTO meeting_analyses(meeting_id,model_run_id,source_revision,model,state,input_json) VALUES (?1,?2,?3,?4,'running',?5)",params![mid,input["model_run_id"].as_i64(),input["source_revision"].as_str(),model,input.to_string()])?;
        let id = tx.last_insert_rowid();
        tx.commit()?;
        Ok((id, input, false))
    }
    fn groq_previous(&self, id: i64, mid: i64) -> Result<Value> {
        let previous: Option<(String, String)> = self.0.query_row(
            "SELECT input_json,result_json FROM meeting_analyses WHERE meeting_id=?1 AND id<?2 AND model=(SELECT model FROM meeting_analyses WHERE id=?2) AND state='completed' ORDER BY id DESC LIMIT 1",
            params![mid, id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).optional()?;
        match previous {
            Some((input, result)) => Ok(json!({
                "input": serde_json::from_str::<Value>(&input)?,
                "result": serde_json::from_str::<Value>(&result)?,
            })),
            None => Ok(Value::Null),
        }
    }
    pub fn groq_complete(&self, id: i64, result: &Value) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        let (mid, raw, state): (i64, String, String) = tx.query_row(
            "SELECT meeting_id,input_json,state FROM meeting_analyses WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        if state != "running" {
            bail!("Анализ уже завершён");
        }
        let input: Value = serde_json::from_str(&raw)?;
        if revision(&tx, mid)? != input["source_revision"].as_str().unwrap() {
            bail!("Транскрипт или участники изменились. Повторите анализ актуальной версии");
        }
        bounded(result, "summary", 20000, true)?;
        let questions = result["open_questions"]
            .as_array()
            .context("Нет списка открытых вопросов")?;
        if questions.len() > 100
            || questions
                .iter()
                .any(|v| v.as_str().is_none_or(|s| s.chars().count() > 2000))
        {
            bail!("Некорректные открытые вопросы");
        }
        let mut proposals = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for (field, kind) in [("decisions", "decision"), ("tasks", "create_task")] {
            let items = result[field]
                .as_array()
                .context("Нет списка предложений Groq")?;
            if items.len() > 96 {
                bail!("Слишком много предложений Groq");
            }
            for item in items {
                let title = bounded(
                    item,
                    if kind == "decision" { "text" } else { "title" },
                    if kind == "decision" { 4000 } else { 500 },
                    true,
                )?;
                let ids = item["source_segment_ids"]
                    .as_array()
                    .context("Нет ссылок на реплики")?;
                if ids.is_empty() || ids.len() > 30 {
                    bail!("Некорректные ссылки на реплики");
                }
                let mut sources = Vec::new();
                for sid in ids {
                    let s = input["segments"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|s| s["id"] == *sid && sid.as_i64().is_some())
                        .context("Groq сослался на несуществующую реплику")?;
                    if !sources.contains(&s) {
                        sources.push(s);
                    }
                }
                sources.sort_by_key(|s| s["start_ms"].as_u64().unwrap_or(0));
                let quote = sources
                    .iter()
                    .map(|s| s["text"].as_str().unwrap_or(""))
                    .collect::<Vec<_>>()
                    .join("\n");
                let mut source = json!({"meeting_id":mid,"model_run_id":input["model_run_id"],"start_ms":sources[0]["start_ms"],"quote":quote,"segment_ids":ids,"analysis_id":id,"source_revision":input["source_revision"]});
                if let Some(topic) = item["topic"].as_str() {
                    let topic = topic.split_whitespace().collect::<Vec<_>>().join(" ");
                    if !topic.is_empty() && topic.chars().count() <= 80 {
                        source["topic"] = json!(topic);
                    }
                }
                let mut p = json!({"kind":kind,"title":title,"description":"","project_id":input["project_id"],"assignee_id":null,"due_date":null,"origin":"groq","source":source});
                if kind == "create_task" {
                    p["description"] = json!(bounded(item, "description", 10000, false)?);
                    if !item["needs_clarification"].is_null()
                        && !item["needs_clarification"].is_boolean()
                    {
                        bail!("Некорректный признак уточнения задачи");
                    }
                    let clarification = if item["clarification"].is_null() {
                        String::new()
                    } else {
                        bounded(item, "clarification", 2000, false)?
                    };
                    let needs_clarification = item["needs_clarification"] == true;
                    if needs_clarification && clarification.is_empty() {
                        bail!("Не указано, что уточнить в поручении");
                    }
                    p["needs_clarification"] = json!(needs_clarification);
                    p["clarification"] = json!(clarification);
                    for k in ["assignee_name", "due_date", "due_time"] {
                        if !item[k].is_null() && !item[k].is_string() {
                            bail!("Некорректные поля задачи");
                        }
                    }
                    if let Some(date) = item["due_date"].as_str() {
                        let parsed = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d")
                            .context("Некорректный срок Groq")?;
                        if parsed.format("%Y-%m-%d").to_string() != date {
                            bail!("Некорректный срок Groq");
                        }
                        p["due_date"] = json!(date);
                    }
                    if let Some(time) = item["due_time"].as_str() {
                        let parsed = chrono::NaiveTime::parse_from_str(time, "%H:%M")
                            .context("Некорректное время срока Groq")?;
                        if parsed.format("%H:%M").to_string() != time || p["due_date"].is_null() {
                            bail!("Время срока должно быть указано вместе с датой");
                        }
                        p["due_time"] = json!(time);
                    }
                    if let Some(name) = item["assignee_name"].as_str() {
                        if name.len() > 500 {
                            bail!("Слишком длинное имя");
                        }
                        let matches: Vec<_> = input["participants"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .filter(|p| {
                                p["name"].as_str().is_some_and(|value| {
                                    value.trim().to_lowercase() == name.trim().to_lowercase()
                                })
                            })
                            .collect();
                        if matches.len() == 1 {
                            p["assignee_id"] = matches[0]["id"].clone();
                        } else {
                            p["description"] = json!(format!(
                                "{}\nПредполагаемый ответственный: {}. Проверьте назначение.",
                                p["description"].as_str().unwrap(),
                                name
                            ));
                        }
                    }
                }
                if seen.insert(format!("{kind}:{}", title.to_lowercase())) {
                    proposals.push(p);
                }
            }
        }
        for p in proposals {
            let mut candidates = tx.prepare(
                "SELECT data_json FROM proposals WHERE is_demo=0 AND json_extract(data_json,'$.origin')='groq' AND json_extract(data_json,'$.source.meeting_id')=?1 AND json_extract(data_json,'$.kind')=?2",
            )?;
            let mut rows = candidates.query(params![mid, p["kind"].as_str()])?;
            let mut duplicate = false;
            while let Some(row) = rows.next()? {
                let old: Value = serde_json::from_str(&row.get::<_, String>(0)?)?;
                if old["title"]
                    .as_str()
                    .zip(p["title"].as_str())
                    .is_some_and(|(a, b)| {
                        a.trim().eq_ignore_ascii_case(b.trim())
                            || a.to_lowercase() == b.to_lowercase()
                            || same_action_title(a, b)
                    })
                    && old["source"]["start_ms"]
                        .as_u64()
                        .zip(p["source"]["start_ms"].as_u64())
                        .is_some_and(|(a, b)| a.abs_diff(b) <= 10_000)
                {
                    duplicate = true;
                    break;
                }
            }
            if duplicate {
                continue;
            }
            tx.execute(
                "INSERT INTO proposals(data_json,is_demo) VALUES (?1,0)",
                [p.to_string()],
            )?;
        }
        tx.execute("UPDATE meeting_analyses SET state='completed',result_json=?2,error=NULL,finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?1",params![id,result.to_string()])?;
        tx.commit()?;
        Ok(())
    }
}
fn helper(payload: Value) -> std::result::Result<Value, String> {
    let path = std::env::var_os("VTRACKER_GROQ_HELPER")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("scripts/groq-analyze.py"));
    let mut child = Command::new("python3")
        .arg(path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "Не удалось запустить адаптер Groq".to_owned())?;
    let written = child
        .stdin
        .take()
        .unwrap()
        .write_all(payload.to_string().as_bytes());
    if written.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err("Адаптер Groq не принял запрос".into());
    }
    let stdout = child.stdout.take().unwrap();
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take(2_097_153).read_to_end(&mut bytes);
        (result, bytes)
    });
    let start = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => {}
            Err(_) => break Err("Ошибка процесса Groq".to_owned()),
        }
        if start.elapsed() > std::time::Duration::from_secs(300) {
            break Err("Истекло время анализа Groq. Повторите вручную".to_owned());
        }
        thread::sleep(std::time::Duration::from_millis(100));
    };
    if status.is_err() {
        let _ = child.kill();
        let _ = child.wait();
    }
    let (read, bytes) = reader.join().map_err(|_| "Ошибка чтения Groq".to_owned())?;
    let status = status?;
    if !status.success() || read.is_err() || bytes.len() > 2_097_152 {
        return Err("Адаптер Groq завершился с ошибкой или слишком большим ответом".into());
    }
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "Некорректный ответ адаптера Groq".to_owned())?;
    if value["ok"] != true {
        return Err(value["error"].as_str().unwrap_or("Ошибка Groq").to_owned());
    }
    Ok(value["value"].clone())
}
pub struct GroqWorker {
    key: Option<String>,
    automatic: bool,
    live_model: Option<String>,
    live_key: Option<String>,
    preview_enabled: bool,
    preview_session: String,
    preview_cursor: i64,
    preview: Value,
    preview_poll: Option<std::time::Instant>,
    last_run: i64,
    model: String,
    storage: String,
    error: Option<String>,
    rx: Option<Receiver<std::result::Result<Value, String>>>,
    operation: String,
    job: Option<i64>,
    account: String,
    base_account: String,
    assistant_id: Option<String>,
    assistant_result: Option<std::result::Result<Value, String>>,
}
impl GroqWorker {
    pub fn new(path: &Path, store: &Store) -> Result<Self> {
        store.0.execute("UPDATE meeting_analyses SET state='interrupted',error='Сервер перезапущен. Повторите анализ вручную.',finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE state IN ('running','pending')",[])?;
        let model: Option<String> = store
            .0
            .query_row(
                "SELECT data_json FROM workspace_settings WHERE key='groq'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let settings = model
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .unwrap_or(Value::Null);
        let model = settings["model"]
            .as_str()
            .map(str::to_owned)
            .filter(|s| valid_model(s))
            .unwrap_or(MODELS[0].into());
        let base_account = format!("{:x}", Sha256::digest(path.to_string_lossy().as_bytes()));
        let account = key_account(&base_account, &model);
        let mut worker = Self {
            key: None,
            automatic: settings["automatic"] == true,
            live_model: settings["live_model"].as_str().filter(|id| valid_model(id)).map(str::to_owned),
            live_key: None,
            preview_enabled: settings["live_preview"] == true,
            preview_session: String::new(),
            preview_cursor: 0,
            preview: Value::Null,
            preview_poll: None,
            last_run: store.0.query_row(
                "SELECT COALESCE(MAX(id),0) FROM model_runs WHERE status='completed'",
                [],
                |r| r.get(0),
            )?,

            model,
            storage: "session".into(),
            error: None,
            rx: None,
            operation: String::new(),
            job: None,
            assistant_id: None,
            assistant_result: None,
            account,
            base_account,
        };
        worker.launch(
            "load_key",
            json!({"mode":"load_key","account":worker.account}),
        );
        Ok(worker)
    }
    fn launch(&mut self, operation: &str, payload: Value) {
        let (tx, rx) = mpsc::channel();
        self.rx = Some(rx);
        self.operation = operation.into();
        thread::spawn(move || {
            let result = if let Some(account) = payload["load_account"].as_str() {
                helper(json!({"mode":"load_key","account":account})).and_then(|value| {
                    let key = value["key"].as_str().filter(|key| !key.is_empty())
                        .ok_or_else(|| "Добавьте API-ключ профиля анализа на лету.".to_owned())?;
                    let mut payload = payload;
                    payload["key"] = json!(key);
                    payload.as_object_mut().unwrap().remove("load_account");
                    helper(payload)
                })
            } else {
                helper(payload)
            };
            let _ = tx.send(result);
        });
    }
    pub fn start_assistant(&mut self, data: &Value) -> Result<Value> {
        if self.rx.is_some() {
            bail!("Groq занят. Повторите запрос чуть позже.");
        }
        let key = self
            .key
            .as_ref()
            .context("Добавьте ключ Groq в настройках")?;
        let id = data["id"]
            .as_str()
            .filter(|id| {
                id.len() == 36
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
            })
            .context("Некорректный идентификатор запроса")?;
        let text = data["text"]
            .as_str()
            .map(str::trim)
            .filter(|text| !text.is_empty() && text.chars().count() <= 1000)
            .context("Введите запрос до 1000 символов")?;
        let today = data["today"]
            .as_str()
            .and_then(|value| chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").ok());
        self.assistant_id = Some(id.to_owned());
        self.assistant_result = None;
        self.launch("assistant", json!({"mode":"assistant","key":key,"model":self.model,
            "text":text,"has_search":data["has_search"] == true,"has_project":data["has_project"] == true,
            "today":today.map(|date| date.to_string())}));
        Ok(json!({"state":"pending"}))
    }

    pub fn assistant_result(&self, id: &str) -> Result<Value> {
        if self.assistant_id.as_deref() != Some(id) {
            bail!("Запрос ассистента устарел");
        }
        Ok(match self.assistant_result.as_ref() {
            None => json!({"state":"pending"}),
            Some(Ok(value)) => json!({"state":"ready","intent":value}),
            Some(Err(error)) => json!({"state":"failed","error":error}),
        })
    }

    pub fn status(&self) -> Value {
        json!({"automatic":self.automatic,"model":self.model,"models":MODELS,"live_model":self.live_model,"live_preview":self.preview_enabled,"has_key":self.key.is_some(),"storage":self.storage,"busy":self.rx.is_some(),"operation":self.operation,"job_id":self.job,"error":self.error})
    }
    pub fn settings(&mut self, store: &Store, data: &Value) -> Result<Value> {
        if self.rx.is_some() {
            bail!("Дождитесь завершения операции Groq");
        }
        let live = data["profile"] == "live";
        let current_live = self.live_model.as_deref().unwrap_or(&self.model);
        let model = data["model"].as_str().unwrap_or(if live { current_live } else { &self.model });
        if !valid_model(model) {
            bail!("Неизвестная модель Groq");
        }
        let key = data["api_key"].as_str().unwrap_or("").trim();
        if !key.is_empty()
            && (!(16..=512).contains(&key.len())
                || !key
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-'))
        {
            bail!("Проверьте формат ключа Groq");
        }
        if data["clear_key"] == true && !key.is_empty() {
            bail!("Выберите сохранение или удаление ключа");
        }
        if live {
            let automatic = data["automatic"].as_bool().unwrap_or(self.automatic);
            let preview_enabled = data["live_preview"].as_bool().unwrap_or(self.preview_enabled);
            let live_model = if data["use_full_profile"] == true { None } else { Some(model.to_owned()) };
            let selected = live_model.as_deref().unwrap_or(&self.model);
            let account = key_account(&self.base_account, selected);
            store.0.execute(
                "INSERT INTO workspace_settings(key,data_json) VALUES ('groq',?1)
                 ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",
                [json!({"model":self.model,"live_model":live_model,"automatic":automatic,"live_preview":preview_enabled}).to_string()],
            )?;
            if provider(selected) != provider(current_live) {
                self.live_key = None;
            }
            self.live_model = live_model;
            self.automatic = automatic;
            self.preview_enabled = preview_enabled;
            self.error = None;
            if !key.is_empty() {
                if account == self.account {
                    self.key = Some(key.into());
                    self.storage = "session".into();
                    self.launch("save_key", json!({"mode":"save_key","account":account,"key":key,"persist":data["persist"]==true}));
                } else {
                    self.live_key = Some(key.into());
                    self.launch("save_live_key", json!({"mode":"save_key","account":account,"key":key,"persist":data["persist"]==true}));
                }
            }
            return Ok(self.status());
        }
        let switched = provider(model) != provider(&self.model);
        let model = model.to_owned();
        if switched {
            if self.live_model.as_deref().is_some_and(|live| provider(live) == provider(model.as_str())) {
                self.live_key = None;
            }
            self.key = None;
            self.storage = "session".into();
            self.account = key_account(&self.base_account, &model);
        }
        self.model = model;
        self.automatic = data["automatic"].as_bool().unwrap_or(self.automatic);
        self.error = None;
        store.0.execute("INSERT INTO workspace_settings(key,data_json) VALUES ('groq',?1) ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",[json!({"model":self.model,"live_model":self.live_model,"automatic":self.automatic,"live_preview":self.preview_enabled}).to_string()])?;
        if data["clear_key"] == true {
            self.key = None;
            self.storage = "session".into();
            self.launch(
                "delete_key",
                json!({"mode":"delete_key","account":self.account}),
            );
        } else if !key.is_empty() {
            self.key = Some(key.into());
            self.storage = "session".into();
            self.launch("save_key",json!({"mode":"save_key","account":self.account,"key":key,"persist":data["persist"]==true}));
        }
        if switched && key.is_empty() && data["clear_key"] != true {
            self.launch("load_key", json!({"mode":"load_key","account":self.account}));
        }
        Ok(self.status())
    }
    pub fn start(&mut self, store: &Store, data: &Value) -> Result<Value> {
        self.start_analysis(store, data, false)
    }
    fn start_analysis(&mut self, store: &Store, data: &Value, incremental: bool) -> Result<Value> {
        if self.rx.is_some() {
            bail!("Groq занят. Дождитесь завершения операции");
        }
        let model = if incremental { self.live_model.as_deref().unwrap_or(&self.model) } else { &self.model };
        let shared_key = provider(model) == provider(&self.model);
        let key = if shared_key {
            Some(self.key.as_deref().context("Добавьте API-ключ провайдера в настройках")?)
        } else {
            self.live_key.as_deref()
        };
        let load_account = if key.is_none() { Some(key_account(&self.base_account, model)) } else { None };
        let mid = data["meeting_id"].as_i64().context("Выберите встречу")?;
        let (id, input, cached) = store.groq_prepare(mid, model, data["consent"] == true)?;
        if cached {
            return Ok(json!({"id":id,"cached":true}));
        }
        let previous = if incremental {
            store.groq_previous(id, mid).unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        self.error = None;
        self.job = Some(id);
        self.launch(
            "analyze",
            json!({"mode":"analyze","key":key,"load_account":load_account,"model":model,"input":input,"automatic":incremental,"previous":previous}),
        );
        Ok(json!({"id":id,"cached":false}))
    }
    pub fn live_preview(&self, session: &str) -> Value {
        if self.preview_enabled && self.preview_session == session {
            self.preview.clone()
        } else {
            Value::Null
        }
    }

    pub fn poll_live(&mut self, store: &Store, active: &Value) -> Result<()> {
        if !self.preview_enabled || self.rx.is_some() || active["state"] != "recording" {
            return Ok(());
        }
        let (Some(session), Some(meeting)) = (active["session_id"].as_str(), active["meeting_id"].as_i64()) else {
            return Ok(());
        };
        if self.preview_poll.is_some_and(|last| last.elapsed() < std::time::Duration::from_secs(2)) {
            return Ok(());
        }
        self.preview_poll = Some(std::time::Instant::now());
        if self.preview_session != session {
            self.preview_session = session.to_owned();
            self.preview_cursor = 0;
            self.preview = Value::Null;
        }
        let count: i64 = store.0.query_row(
            "SELECT COUNT(*) FROM live_chunks WHERE session_id=?1 AND state='completed' AND json_array_length(result_json)>0",
            [session], |row| row.get(0),
        )?;
        if count < self.preview_cursor + 6 {
            return Ok(());
        }
        let Some((title, date)) = store.0.query_row(
            "SELECT title,created_at FROM meetings WHERE id=?1 AND is_demo=0", [meeting],
            |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?)),
        ).optional()? else {
            return Ok(());
        };
        let mut statement = store.0.prepare(
            "SELECT result_json FROM live_chunks WHERE session_id=?1 AND state='completed'
             AND json_array_length(result_json)>0 ORDER BY sequence DESC LIMIT 12",
        )?;
        let rows = statement.query_map([session], |row| row.get::<_,String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut segments = Vec::new();
        for row in rows.iter().rev() {
            for segment in serde_json::from_str::<Vec<Value>>(row)? {
                if let Some(text) = segment["text"].as_str().filter(|text| !text.trim().is_empty()) {
                    segments.push(json!({"id":segments.len()+1,"text":text,"start_ms":segment["start_ms"]}));
                }
            }
        }
        if segments.is_empty() {
            return Ok(());
        }
        let model = self.live_model.as_deref().unwrap_or(&self.model);
        let key = if provider(model) == provider(&self.model) { self.key.as_deref() } else { self.live_key.as_deref() };
        let load_account = key.is_none().then(|| key_account(&self.base_account, model));
        let payload = json!({
            "mode":"analyze","key":key,"load_account":load_account,"model":model,
            "input":{"title":title,"created_at":date,"timezone":store.workspace_timezone()?,
                     "participants":[],"segments":segments}
        });
        self.preview_cursor = count;
        self.preview["running"] = json!(true);
        self.preview["error"] = Value::Null;
        self.launch("live_preview", payload);
        Ok(())
    }

    pub fn poll_automatic(&mut self, store: &Store) -> Result<()> {
        if self.rx.is_some() {
            return Ok(());
        }
        let live_model = self.live_model.as_deref().unwrap_or(&self.model);
        let uses_full_key = provider(live_model) == provider(&self.model);
        if !self.automatic || (uses_full_key && self.key.is_none()) {
            self.last_run = store.0.query_row(
                "SELECT COALESCE(MAX(id),0) FROM model_runs WHERE status='completed'",
                [],
                |r| r.get(0),
            )?;
            return Ok(());
        }
        let next: Option<(i64, i64)> = store.0.query_row(
            "SELECT r.id,r.meeting_id FROM model_runs r JOIN meetings m ON m.id=r.meeting_id
             WHERE r.status='completed' AND r.id>?1 AND m.is_demo=0
               AND m.status NOT IN ('recording','paused')
               AND r.id=(SELECT MAX(id) FROM model_runs WHERE meeting_id=r.meeting_id AND status='completed')
             ORDER BY r.id LIMIT 1",
            [self.last_run], |r| Ok((r.get(0)?, r.get(1)?)),
        ).optional()?;
        if let Some((run, mid)) = next {
            self.last_run = run;
            if let Err(error) =
                self.start_analysis(store, &json!({"meeting_id":mid,"consent":true}), true)
            {
                self.error = Some(error.to_string());
            }
        }
        Ok(())
    }
    pub fn poll(&mut self, store: &Store) -> Result<()> {
        let outcome = match self.rx.as_ref().map(|rx| rx.try_recv()) {
            Some(Ok(r)) => Some(r),
            Some(Err(mpsc::TryRecvError::Disconnected)) => {
                Some(Err("Адаптер Groq завершился без ответа".into()))
            }
            _ => None,
        };
        if let Some(mut result) = outcome {
            self.rx = None;
            if self.operation == "assistant" {
                self.assistant_result = Some(result);
                self.operation.clear();
                return Ok(());
            }
            if self.operation == "live_preview" {
                self.preview["running"] = json!(false);
                match result {
                    Ok(value) => self.preview["result"] = value,
                    Err(error) => self.preview["error"] = json!(error),
                }
                self.operation.clear();
                return Ok(());
            }
            if self.operation == "analyze" {
                let id = self.job.take().unwrap();
                if let Ok(value) = &result {
                    if let Err(e) = store.groq_complete(id, value) {
                        result = Err(e.to_string());
                    }
                }
                if let Err(e) = &result {
                    store.0.execute("UPDATE meeting_analyses SET state='failed',error=?2,finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?1 AND state='running'",params![id,e])?;
                }
            } else if let Ok(value) = &result {
                if self.operation == "load_key" {
                    self.key = value["key"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned);
                    if self.key.is_some() {
                        self.storage = "keychain".into();
                    }
                } else if self.operation == "save_key" {
                    self.storage = value["storage"].as_str().unwrap_or("session").into();
                }
            }
            self.error = result.err();
            self.operation.clear();
        }
        Ok(())
    }
}
