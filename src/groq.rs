//! Opt-in, text-only Groq analysis. Credentials never enter SQLite or public snapshots.
use crate::{local_analysis, workspace::change_fields, Store};
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
const ANALYSIS_POLICY: &str = "vtask-groq-context-tasks-v14";

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
    hash.update(ANALYSIS_POLICY.as_bytes());
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
pub(crate) fn same_action_title(first: &str, second: &str) -> bool {
    fn normalized(title: &str) -> Vec<String> {
        title.to_lowercase().replace('ё', "е")
            .split(|ch: char| !ch.is_alphanumeric())
            .filter(|word| !word.is_empty())
            .map(str::to_owned)
            .collect()
    }
    normalized(first) == normalized(second)
}

fn search_terms(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split(|ch: char| !ch.is_alphanumeric())
        .filter(|word| word.chars().count() >= 4)
        .map(|word| word.to_lowercase().replace('ё', "е").chars().take(4).collect())
}

fn bundle_task_changes(proposals: Vec<Value>, input: &Value) -> Vec<Value> {
    let mut bundled = Vec::new();
    for task in input["project_tasks"].as_array().into_iter().flatten() {
        let changes: Vec<_> = proposals.iter().filter(|p| {
            p["task_id"] == task["id"] && matches!(p["kind"].as_str(), Some("change_due" | "change_assignee"))
        }).collect();
        if !["change_due", "change_assignee"].iter().all(|kind| changes.iter().any(|p| p["kind"] == *kind)) {
            continue;
        }
        let mut bundle = changes[0].clone();
        bundle["kind"] = json!("change_task");
        let mut proposed = json!({});
        let mut conflicts = Vec::new();
        for (kind, keys) in [("change_due", &["due_date", "due_time"][..]), ("change_assignee", &["assignee_id"][..])] {
            let mut values = changes.iter().filter(|p| p["kind"] == kind).map(|p| &p["proposed"]);
            let first = values.next().unwrap();
            if values.any(|value| value != first) {
                conflicts.push(if kind == "change_due" { "срок" } else { "исполнителя" });
                for key in keys { proposed[*key] = Value::Null; }
            } else {
                for key in keys { proposed[*key] = first[*key].clone(); }
            }
        }
        bundle["proposed"] = proposed;
        bundle["due_date"] = bundle["proposed"]["due_date"].clone();
        bundle["due_time"] = bundle["proposed"]["due_time"].clone();
        bundle["assignee_id"] = bundle["proposed"]["assignee_id"].clone();
        let ids: std::collections::HashSet<_> = changes.iter().flat_map(|p| {
            p["source"]["segment_ids"].as_array().into_iter().flatten().filter_map(Value::as_i64)
        }).collect();
        let segments: Vec<_> = input["segments"].as_array().into_iter().flatten()
            .filter(|s| s["id"].as_i64().is_some_and(|id| ids.contains(&id))).collect();
        bundle["source"]["segment_ids"] = json!(segments.iter().map(|s| &s["id"]).collect::<Vec<_>>());
        bundle["source"]["segment_times_ms"] = json!(segments.iter().map(|s| &s["start_ms"]).collect::<Vec<_>>());
        let finding_ids: std::collections::BTreeSet<_> = changes.iter().flat_map(|p| {
            p["source"]["finding_ids"].as_array().into_iter().flatten().filter_map(Value::as_str)
        }).collect();
        bundle["source"]["finding_ids"] = json!(finding_ids);
        if !changes.iter().all(|p| p["source"]["person_id"] == changes[0]["source"]["person_id"]) {
            bundle["source"]["person_id"] = Value::Null;
        }
        bundle["source"]["start_ms"] = segments[0]["start_ms"].clone();
        bundle["source"]["quote"] = json!(segments.iter().filter_map(|s| s["text"].as_str())
            .collect::<Vec<_>>().join("\n"));
        let details: std::collections::BTreeSet<_> = changes.iter().filter_map(|p| p["description"].as_str())
            .filter(|text| !text.is_empty()).collect();
        bundle["description"] = json!(details.into_iter().collect::<Vec<_>>().join("\n"));
        let mut clarifications: std::collections::BTreeSet<_> = changes.iter()
            .filter_map(|p| p["clarification"].as_str())
            .filter(|text| !text.is_empty()).map(str::to_owned).collect();
        if !conflicts.is_empty() {
            clarifications.insert(format!("В протоколе указаны разные значения. Уточните {}.", conflicts.join(" и ")));
        }
        bundle["needs_clarification"] = json!(!clarifications.is_empty());
        bundle["clarification"] = json!(clarifications.into_iter().collect::<Vec<_>>().join("\n"));
        bundled.push(bundle);
    }
    let mut result: Vec<_> = proposals.into_iter().filter(|p| {
        !matches!(p["kind"].as_str(), Some("change_due" | "change_assignee"))
            || !bundled.iter().any(|bundle| bundle["task_id"] == p["task_id"])
    }).collect();
    result.extend(bundled);
    result
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

fn analysis_source(input: &Value, mid: i64, analysis: i64, item: &Value) -> Result<Value> {
    let ids = item["source_segment_ids"].as_array().context("Нет ссылок на реплики")?;
    if ids.is_empty() || ids.len() > 30 {
        bail!("Некорректные ссылки на реплики");
    }
    let mut sources = Vec::new();
    for id in ids {
        let segment = input["segments"].as_array().into_iter().flatten()
            .find(|segment| id.is_i64() && segment["id"] == *id)
            .context("Анализ сослался на несуществующую реплику")?;
        if !sources.contains(&segment) { sources.push(segment); }
    }
    sources.sort_by_key(|s| s["start_ms"].as_u64().unwrap_or(0));
    let quote = sources.iter().filter_map(|s| s["text"].as_str()).collect::<Vec<_>>().join("\n");
    let person = &sources[0]["person_id"];
    let speaker = if sources.iter().all(|s| s["person_id"] == *person) { person.clone() } else { Value::Null };
    let mut source = json!({"meeting_id":mid,"model_run_id":input["model_run_id"],
        "start_ms":sources[0]["start_ms"],"quote":quote,"segment_ids":ids,"person_id":speaker,
        "analysis_id":analysis,"source_revision":input["source_revision"]});
    if let Some(topic) = item["topic"].as_str() {
        let topic = topic.split_whitespace().collect::<Vec<_>>().join(" ");
        if !topic.is_empty() && topic.chars().count() <= 80 { source["topic"] = json!(topic); }
    }
    Ok(source)
}

impl Store {
    pub fn ai_budget(&self, change: Option<&Value>) -> Result<Value> {
        if let Some(change) = change {
            let mut limits = serde_json::Map::new();
            for key in ["daily_tokens", "monthly_tokens"] {
                let limit = change[key].as_u64().filter(|limit| *limit <= 1_000_000_000)
                    .context("Введите лимит от 0 до 1 000 000 000 токенов")?;
                limits.insert(key.to_owned(), json!(limit));
            }
            self.0.execute(
                "INSERT INTO workspace_settings(key,data_json) VALUES ('ai_budget',?1)
                 ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",
                [Value::Object(limits).to_string()],
            )?;
        }
        let limits: Option<String> = self.0.query_row(
            "SELECT data_json FROM workspace_settings WHERE key='ai_budget'", [], |row| row.get(0),
        ).optional()?;
        let limits = limits.map(|json| serde_json::from_str::<Value>(&json)).transpose()?.unwrap_or(Value::Null);
        let today = chrono::Utc::now().date_naive().to_string();
        let month = format!("{}-01", &today[..7]);
        let mut statement = self.0.prepare(
            "SELECT stage,phase,sum(day=?1),sum(CASE WHEN day=?1 THEN charged_tokens ELSE 0 END),
                    count(*),sum(charged_tokens),sum(coalesce(input_tokens,0)),sum(coalesce(output_tokens,0)),
                    sum(CASE WHEN state IN ('estimated','reserved') THEN charged_tokens ELSE 0 END)
             FROM ai_usage WHERE day BETWEEN ?2 AND ?1 GROUP BY stage,phase ORDER BY stage,phase",
        )?;
        let stages = statement.query_map(params![today,month], |row| Ok(json!({
            "stage":row.get::<_,String>(0)?, "phase":row.get::<_,String>(1)?,
            "today_requests":row.get::<_,i64>(2)?, "today_tokens":row.get::<_,i64>(3)?,
            "month_requests":row.get::<_,i64>(4)?, "month_tokens":row.get::<_,i64>(5)?,
            "input_tokens":row.get::<_,i64>(6)?, "output_tokens":row.get::<_,i64>(7)?,
            "estimated_tokens":row.get::<_,i64>(8)?
        })))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let total = |key: &str| stages.iter().filter_map(|row| row[key].as_i64()).sum::<i64>();
        Ok(json!({
            "daily_tokens":limits["daily_tokens"].as_u64().unwrap_or(0),
            "monthly_tokens":limits["monthly_tokens"].as_u64().unwrap_or(0),
            "today_tokens":total("today_tokens"),"month_tokens":total("month_tokens"),
            "estimated_tokens":total("estimated_tokens"),"stages":stages
        }))
    }

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
        let mut earlier = self.0.prepare(
            "SELECT json_extract(data_json,'$.title'), json_extract(data_json,'$.source.start_ms')
             FROM proposals
             WHERE is_demo=0 AND status IN ('pending','accepted')
               AND json_extract(data_json,'$.origin')='groq'
               AND json_extract(data_json,'$.kind')='create_task'
               AND json_extract(data_json,'$.source.meeting_id')=?1
             ORDER BY id DESC LIMIT 48",
        )?;
        let discussed_tasks = earlier
            .query_map([mid], |row| {
                Ok(json!({"title": row.get::<_, String>(0)?, "start_ms": row.get::<_, Option<i64>>(1)?}))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let (project_tasks, project_decisions) = if let Some(project) = project {
            let (project_tasks, active_decisions) = self.analysis_project_context(project)?;
            let transcript_terms: std::collections::HashSet<_> = segments.iter()
                .filter_map(|s| s["text"].as_str()).flat_map(search_terms).collect();
            let explicit_ids: std::collections::HashSet<i64> = segments.iter().filter_map(|s| s["text"].as_str())
                .flat_map(|text| text.split('#').skip(1))
                .filter_map(|tail| tail[..tail.find(|ch: char| !ch.is_ascii_digit()).unwrap_or(tail.len())]
                    .parse().ok()).collect();
            let mut candidates: Vec<_> = project_tasks.iter()
                .filter(|task| task["stage_kind"] == "active"
                    || task["id"].as_i64().is_some_and(|id| explicit_ids.contains(&id))).collect();
            candidates.sort_by_cached_key(|task| {
                let title_hits = search_terms(task["title"].as_str().unwrap_or(""))
                    .collect::<std::collections::HashSet<_>>().intersection(&transcript_terms).count();
                let details_hits = search_terms(task["description"].as_str().unwrap_or(""))
                    .collect::<std::collections::HashSet<_>>().intersection(&transcript_terms).count();
                let mentioned = task["id"].as_i64().is_some_and(|id| explicit_ids.contains(&id));
                std::cmp::Reverse((mentioned, title_hits, details_hits, task["id"].as_i64()))
            });
            let tasks: Vec<_> = candidates.into_iter().take(24).map(|task| {
                let details: String = task["description"].as_str().unwrap_or("").chars().take(240).collect();
                json!({"id":task["id"],"title":task["title"],"description":details,"revision":task["revision"],
                    "stage_id":task["stage_id"],"stage_title":task["stage_title"],"stage_kind":task["stage_kind"],
                    "blocked":task["blocked"],"blocked_reason":task["blocked_reason"],
                    "due_date":task["due_date"],"due_time":task["due_time"],"assignee_id":task["assignee_id"]})
            }).collect();
            let decisions = active_decisions.into_iter()
                .filter(|decision| tasks.iter().any(|task| task["id"] == decision["task_id"]))
                .take(12).collect::<Vec<_>>();
            (tasks, decisions)
        } else { (Vec::new(), Vec::new()) };
        let timezone = self.workspace_timezone()?;
        let value = json!({"meeting_id":mid,"title":title,"created_at":date,"timezone":timezone,"project_id":project,"model_run_id":run,"source_revision":revision(&self.0,mid)?,"participants":people,"segments":segments,"discussed_tasks":discussed_tasks,"project_tasks":project_tasks,"project_decisions":project_decisions});
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
        let mut stmt=self.0.prepare("SELECT id,state,model,CASE WHEN instr(source_revision,':run:') > 0 THEN substr(source_revision,1,instr(source_revision,':run:')-1) ELSE source_revision END,result_json,error,created_at FROM meeting_analyses WHERE meeting_id=?1 ORDER BY id DESC")?;
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
        self.groq_prepare_run(mid, model, consent, false)
    }

    pub fn groq_prepare_run(&self, mid: i64, model: &str, consent: bool, fresh: bool) -> Result<(i64, Value, bool)> {
        self.prepare_analysis(mid, model, consent, fresh, None, false)
    }

    fn prepare_analysis(&self, mid: i64, model: &str, consent: bool, fresh: bool,
                        mode: Option<&str>, force: bool) -> Result<(i64, Value, bool)> {
        let local = mode == Some("local") && model == local_analysis::MODEL;
        if !consent && !local {
            bail!("Подтвердите отправку текста в Groq");
        }
        if !local && !valid_model(model) {
            bail!("Неизвестная модель Groq");
        }
        let mut input = self.groq_snapshot(mid)?;
        input["analysis_policy"] = json!(ANALYSIS_POLICY);
        if let Some(mode) = mode {
            input["analysis_mode"] = json!(mode);
        }
        let tx = self.0.unchecked_transaction()?;
        if revision(&tx, mid)? != input["source_revision"].as_str().unwrap() {
            bail!("Встреча изменилась. Откройте анализ заново");
        }
        if fresh {
            let active: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM meeting_analyses WHERE meeting_id=?1 AND state IN ('running','pending'))",
                [mid], |row| row.get(0),
            )?;
            if active { bail!("Анализ уже выполняется"); }
            if mode.is_some() && !force {
                let previous: Option<(i64, String, String)> = tx.query_row(
                    "SELECT id,model,input_json FROM meeting_analyses
                     WHERE meeting_id=?1 AND state='completed' ORDER BY id DESC LIMIT 1",
                    [mid], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                ).optional()?;
                if let Some((id, previous_model, raw)) = previous {
                    let previous: Value = serde_json::from_str(&raw)?;
                    let same_context = ["analysis_mode", "analysis_policy", "source_revision"].iter()
                        .all(|key| input[*key] == previous[*key])
                        && (mode == Some("automatic") || ["project_tasks", "project_decisions"].iter()
                            .all(|key| input[*key] == previous[*key]));
                    if previous_model == model && same_context {
                        return Ok((id, input, true));
                    }
                }
            }
            // The stored run key distinguishes retries. The input retains the actual transcript revision.
            let sequence: i64 = tx.query_row("SELECT coalesce(max(id),0)+1 FROM meeting_analyses", [], |row| row.get(0))?;
            let run_key = format!("{}:run:{sequence}", input["source_revision"].as_str().unwrap());
            tx.execute(
                "INSERT INTO meeting_analyses(meeting_id,model_run_id,source_revision,model,state,input_json) VALUES (?1,?2,?3,?4,'running',?5)",
                params![mid,input["model_run_id"].as_i64(),run_key,model,input.to_string()],
            )?;
            let id = tx.last_insert_rowid();
            tx.commit()?;
            return Ok((id, input, false));
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
            "SELECT a.input_json,a.result_json FROM meeting_analyses a JOIN meeting_analyses current ON current.id=?2
             WHERE a.meeting_id=?1 AND a.id<?2 AND a.model=current.model AND a.state='completed'
               AND json_extract(a.input_json,'$.analysis_policy')=json_extract(current.input_json,'$.analysis_policy')
               AND json_extract(a.input_json,'$.analysis_mode')=json_extract(current.input_json,'$.analysis_mode')
             ORDER BY a.id DESC LIMIT 1",
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
        let origin = if input["analysis_mode"] == "local" { "local_analysis" } else { "groq" };
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
        let mut findings = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for (field, default_kind) in [("decisions", "decision"), ("tasks", "create_task")] {
            let items = result[field]
                .as_array()
                .context("Нет списка предложений Groq")?;
            if items.len() > 96 {
                bail!("Слишком много предложений Groq");
            }
            for item in items {
                let kind = if field == "tasks" {
                    match item["kind"].as_str().unwrap_or(default_kind) {
                        kind @ ("create_task" | "change_due" | "change_assignee" | "change_status" | "change_blocked") => kind,
                        _ => bail!("Неизвестный тип предложения анализа"),
                    }
                } else {
                    default_kind
                };
                let title = bounded(
                    item,
                    if kind == "decision" { "text" } else { "title" },
                    if kind == "decision" { 4000 } else { 500 },
                    true,
                )?;
                let mut source = analysis_source(&input, mid, id, item)?;
                let quote = source["quote"].as_str().unwrap_or_default().to_owned();
                let finding_id = format!("{id}:{}", findings.len() + 1);
                source["finding_ids"] = json!([finding_id]);
                let mut p = json!({"kind":kind,"title":title,"description":"","project_id":input["project_id"],"assignee_id":null,"due_date":null,"origin":origin,"source":source});
                if field == "tasks" {
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
                            let key = |value: &str| value.trim().to_lowercase().replace('ё', "е");
                            let requested = key(name);
                            let mut directory = tx.prepare("SELECT id,name FROM people WHERE is_demo=0")?;
                            let entries = directory.query_map([], |row| Ok((row.get::<_,i64>(0)?, row.get::<_,String>(1)?)))?;
                            let mut candidates = Vec::new();
                            for person in entries {
                                let (id, name) = person?;
                                if key(&name) == requested { candidates.push(id); }
                            }
                            if candidates.len() == 1 {
                                p["assignee_id"] = json!(candidates[0]);
                            } else {
                                p["description"] = json!(format!(
                                "{}\nПредполагаемый ответственный: {}. Проверьте назначение.",
                                p["description"].as_str().unwrap(),
                                name
                                ));
                            }
                        }
                    }
                }
                if kind == "create_task" {
                    let title_terms: std::collections::HashSet<_> = search_terms(&title).collect();
                    let candidates: Vec<_> = input["project_tasks"].as_array().into_iter().flatten()
                        .filter(|task| item["task_id"].as_i64().is_some() && task["id"] == item["task_id"]
                            || task["title"].as_str().is_some_and(|name|
                                same_action_title(name, &title)
                                || search_terms(name).collect::<std::collections::HashSet<_>>()
                                    .intersection(&title_terms).count() >= 2))
                        .take(6).map(|task| &task["id"]).collect();
                    if !candidates.is_empty() {
                        p["candidate_task_ids"] = json!(candidates);
                        p["needs_clarification"] = json!(true);
                        if p["clarification"] == "" {
                            p["clarification"] = json!("Проверьте, относится ли поручение к одной из задач проекта.");
                        }
                    }
                }
                if kind.starts_with("change_") {
                    if let Some(task_id) = item["task_id"].as_i64() {
                        if let Some(task) = input["project_tasks"].as_array().into_iter().flatten()
                            .find(|task| task["id"] == task_id)
                        {
                            p["task_id"] = json!(task_id);
                            p["title"] = task["title"].clone();
                        }
                    }
                    if p["task_id"].is_null() && p["needs_clarification"] != true {
                        let mut matches = input["project_tasks"].as_array().into_iter().flatten()
                            .filter(|task| task["title"].as_str().is_some_and(|name| same_action_title(name, &title)));
                        if let Some(task) = matches.next() {
                            if matches.next().is_none() {
                                p["task_id"] = task["id"].clone();
                                p["title"] = task["title"].clone();
                            }
                        }
                    }
                    if p["task_id"].is_null() {
                        let words: std::collections::HashSet<_> = search_terms(&title).chain(search_terms(&quote)).collect();
                        let candidates: Vec<_> = input["project_tasks"].as_array().into_iter().flatten()
                            .filter(|task| task["title"].as_str().is_some_and(|name|
                                search_terms(name).any(|word| words.contains(&word))))
                            .take(6).map(|task| &task["id"]).collect();
                        p["candidate_task_ids"] = json!(candidates);
                    }
                }
                match kind {
                    "change_due" => p["proposed"] = json!({"due_date": p["due_date"], "due_time": p["due_time"]}),
                    "change_assignee" => p["proposed"] = json!({"assignee_id": p["assignee_id"]}),
                    "change_status" => {
                        let stage = bounded(item, "stage_title", 500, true)?;
                        p["proposed"] = json!({"stage_title": stage});
                    }
                    "change_blocked" => {
                        let blocked = item["blocked"].as_bool().context("Укажите состояние блокировки")?;
                        let reason = if blocked { bounded(item, "blocked_reason", 2000, true)? } else { String::new() };
                        p["proposed"] = json!({"blocked":blocked,"blocked_reason":reason});
                    }
                    _ => {}
                }
                let finding_kind = match kind {
                    "create_task" => "new_task", "decision" => "decision",
                    "change_blocked" => "blocker", _ => "task_update",
                };
                findings.push(json!({"id":finding_id,"kind":finding_kind,"text":title,
                    "status":"review","source":p["source"],"project_id":input["project_id"],"task_id":p["task_id"]}));
                let mut changes = Vec::new();
                if kind == "change_due" && item["assignee_name"].as_str().is_some_and(|name| !name.trim().is_empty()) {
                    let mut assignment = p.clone();
                    assignment["kind"] = json!("change_assignee");
                    assignment["proposed"] = json!({"assignee_id": p["assignee_id"]});
                    changes.push(assignment);
                }
                if kind == "change_assignee" && !p["due_date"].is_null() {
                    let mut deadline = p.clone();
                    deadline["kind"] = json!("change_due");
                    deadline["proposed"] = json!({"due_date": p["due_date"], "due_time": p["due_time"]});
                    changes.push(deadline);
                }
                changes.push(p);
                for mut proposal in changes {
                    match proposal["kind"].as_str() {
                        Some("change_due") => proposal["assignee_id"] = Value::Null,
                        Some("change_assignee") => {
                            proposal["due_date"] = Value::Null;
                            proposal["due_time"] = Value::Null;
                        }
                        _ => {}
                    }
                    let identity = json!([proposal["kind"], proposal["task_id"], proposal["title"],
                                          proposal["assignee_id"], proposal["due_date"], proposal["due_time"],
                                          proposal["proposed"], proposal["source"]["segment_ids"]]);
                    if seen.insert(identity.to_string()) {
                        proposals.push(proposal);
                    }
                }
            }
        }
        if let Some(observations) = result.get("observations") {
            let observations = observations.as_array().filter(|items| items.len() <= 96)
                .context("Некорректный список наблюдений")?;
            for item in observations {
                let kind = item["kind"].as_str()
                    .filter(|kind| ["status_update", "question", "information"].contains(kind))
                    .context("Неизвестный тип наблюдения")?;
                let text = bounded(item, "text", 4000, true)?;
                let source = analysis_source(&input, mid, id, item)?;
                let task_id = item["task_id"].as_i64().filter(|task_id| {
                    input["project_tasks"].as_array().into_iter().flatten().any(|task| task["id"] == *task_id)
                });
                findings.push(json!({"id":format!("{id}:{}",findings.len()+1),"kind":kind,"text":text,
                    "status":"recorded","source":source,"task_id":task_id,"project_id":input["project_id"]}));
            }
        }
        tx.execute(
            "UPDATE proposals
             SET status='rejected',data_json=json_set(data_json,'$.superseded_by_analysis_id',?2)
             WHERE is_demo=0 AND status='pending'
               AND json_extract(data_json,'$.origin')=?3
               AND json_extract(data_json,'$.source.meeting_id')=?1",
            params![mid,id,origin],
        )?;
        for mut p in bundle_task_changes(proposals, &input) {
            if p["task_id"].is_null() && p["needs_clarification"] != true
                && matches!(p["kind"].as_str(), Some("change_due" | "change_assignee" | "change_status" | "change_blocked")) {
                let mut confirmed = tx.prepare(
                    "SELECT json_extract(data_json,'$.title'), json_extract(data_json,'$.confirmed_task_id')
                     FROM proposals WHERE is_demo=0 AND status='accepted'
                       AND json_extract(data_json,'$.kind')='create_task'
                       AND json_extract(data_json,'$.source.meeting_id')=?1",
                )?;
                let mut rows = confirmed.query([mid])?;
                let mut matched_tasks = std::collections::HashSet::new();
                while let Some(row) = rows.next()? {
                    let title: Option<String> = row.get(0)?;
                    let task: Option<i64> = row.get(1)?;
                    if let (Some(title), Some(task)) = (title, task) {
                        if p["title"].as_str().is_some_and(|name| title.trim().to_lowercase() == name.trim().to_lowercase()) {
                            matched_tasks.insert(task);
                        }
                    }
                }
                if matched_tasks.len() == 1 {
                    p["task_id"] = json!(matched_tasks.into_iter().next());
                }
            }
            let kind = p["kind"].as_str().unwrap_or_default();
            let fields = change_fields(kind);
            if !fields.is_empty() && !p["task_id"].is_null() {
                if let Some(task) = input["project_tasks"].as_array().into_iter().flatten()
                    .find(|task| task["id"] == p["task_id"])
                {
                    let already_applied = match kind {
                        // The model gives a title; approval is where it becomes a specific stage ID.
                        "change_status" => false,
                        "change_assignee" if p["proposed"]["assignee_id"].is_null() => false,
                        "change_blocked" if p["proposed"]["blocked"] == false => task["blocked"] == false,
                        _ => fields.iter().all(|key| p["proposed"][*key] == task[*key]),
                    };
                    if already_applied && p["needs_clarification"] != true {
                        continue;
                    }
                    let mut baseline = serde_json::Map::new();
                    baseline.insert("revision".to_owned(), task["revision"].clone());
                    baseline.extend(fields.iter().map(|key| (key.to_string(), task[*key].clone())));
                    p["base_task"] = json!(baseline);
                }
            }
            let mut candidates = tx.prepare(
                "SELECT data_json FROM proposals WHERE is_demo=0 AND status IN ('accepted','pending') AND json_extract(data_json,'$.origin') IN ('groq','local_analysis') AND json_extract(data_json,'$.source.meeting_id')=?1 AND json_extract(data_json,'$.kind')=?2",
            )?;
            let mut rows = candidates.query(params![mid, p["kind"].as_str()])?;
            let mut duplicate = false;
            while let Some(row) = rows.next()? {
                let old: Value = serde_json::from_str(&row.get::<_, String>(0)?)?;
                if !old["task_id"].is_null() && !p["task_id"].is_null() && old["task_id"] != p["task_id"] {
                    continue;
                }
                let same_commitment = ["project_id", "assignee_id", "due_date", "due_time", "proposed"]
                    .iter()
                    .all(|field| old[*field] == p[*field]);
                let same_evidence = old["source"]["quote"] == p["source"]["quote"];
                let nearby = old["source"]["start_ms"]
                        .as_u64()
                        .zip(p["source"]["start_ms"].as_u64())
                        .is_some_and(|(a, b)| a.abs_diff(b) <= 10_000);
                if ((same_evidence && (p["kind"] != "change_task" || same_commitment)) || (same_commitment && nearby))
                    && old["title"]
                    .as_str()
                    .zip(p["title"].as_str())
                    .is_some_and(|(a, b)| same_action_title(a, b))
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
        let mut saved = result.clone();
        saved["findings"] = json!(findings);
        tx.execute("UPDATE meeting_analyses SET state='completed',result_json=?2,error=NULL,finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?1",params![id,saved.to_string()])?;
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
    database: std::path::PathBuf,
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
            database: path.to_owned(),
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
    fn launch(&mut self, operation: &str, mut payload: Value) {
        if matches!(operation, "analyze" | "live_preview" | "assistant") {
            payload["database"] = json!(self.database);
            payload["stage"] = json!(match operation {
                "analyze" if payload["automatic"] == true => "automatic",
                "analyze" => "manual",
                "live_preview" => "live",
                _ => "assistant",
            });
        }
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
        if data["local"] == true {
            if self.job.is_some() { bail!("Дождитесь завершения анализа совещания"); }
            let mid = data["meeting_id"].as_i64().context("Выберите встречу")?;
            let (id, input, cached) =
                store.prepare_analysis(mid, local_analysis::MODEL, false, true, Some("local"), false)?;
            if !cached {
                if let Err(error) = store.groq_complete(id, &local_analysis::analyze(&input)) {
                    store.0.execute("UPDATE meeting_analyses SET state='failed',error=?2,
                        finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?1",
                        params![id,error.to_string()])?;
                    return Err(error);
                }
            }
            return Ok(json!({"id":id,"cached":cached,"local":true}));
        }
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
        let force = !incremental && data["force"] == true;
        let mode = if incremental { "automatic" } else { "manual" };
        let (id, input, cached) = store.prepare_analysis(mid, model, data["consent"] == true, true, Some(mode), force)?;
        if cached {
            return Ok(json!({"id":id,"cached":true}));
        }
        let previous = if !force {
            store.groq_previous(id, mid).unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        self.error = None;
        self.job = Some(id);
        self.launch(
            "analyze",
            json!({"mode":"analyze","key":key,"load_account":load_account,"model":model,"input":input,"automatic":incremental,"previous":previous,"force":force}),
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
             AND json_array_length(result_json)>0 ORDER BY sequence DESC LIMIT ?2",
        )?;
        let window = (count - self.preview_cursor + 2).min(12);
        let rows = statement.query_map(params![session,window], |row| row.get::<_,String>(0))?
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
