use rusqlite::{params, Connection};
use serde_json::{json, Value};
use vtracker::{
    groq::{GroqWorker, MODELS, OLLAMA_MODEL},
    Store,
};
fn setup() -> (tempfile::TempDir, Store, i64, i64) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let s = Store::open(&path).unwrap();
    let c = Connection::open(&path).unwrap();
    let (m, seg) = meeting_with_transcript(&s, &c, "Planning", "Prepare the report by Friday");
    (dir, s, m, seg)
}
fn meeting_with_transcript(s: &Store, c: &Connection, title: &str, text: &str) -> (i64, i64) {
    let m = s.create_meeting(title).unwrap();
    c.execute(
        "INSERT INTO processing_jobs(meeting_id,kind,status) VALUES (?1,'transcribe','completed')",
        [m],
    )
    .unwrap();
    let j = c.last_insert_rowid();
    c.execute("INSERT INTO model_runs(job_id,meeting_id,model_path,model_sha256,engine_path,engine_sha256,language,status,inputs_json) VALUES (?1,?2,'fixture',?3,'fixture',?3,'ru','completed','[]')",params![j,m,"0".repeat(64)]).unwrap();
    let run = c.last_insert_rowid();
    c.execute("INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,0,2000,?2,'[]')",params![run,text]).unwrap();
    let seg = c.last_insert_rowid();
    (m, seg)
}
fn output(seg: i64) -> Value {
    json!({"summary":"Agreed to prepare a report.","open_questions":["Who reviews it?"],"decisions":[{"text":"Prepare report","source_segment_ids":[seg]}],"tasks":[{"title":"Prepare report","description":"Draft report","assignee_name":null,"due_date":null,"source_segment_ids":[seg]}]})
}
#[test]
fn protocol_titles_use_analysis_and_keep_meeting_metadata() {
    let (_dir, store, meeting, segment) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Отчётность","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Совещание","project_id":project["id"],"participants":[],
        "scheduled_at":"2026-11-20T22:30:00Z"
    }})).unwrap();
    let (old_run, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut result = output(segment);
    result["summary"] = json!("В ходе обсуждения рассматриваются возможности использования жмыха как сырья для производства алкоголя и как отдельного продукта.");
    store.groq_complete(old_run, &result).unwrap();
    assert_eq!(store.export(meeting).unwrap()["meeting"]["display_title"], "Возможности использования жмыха как сырья для производства алкоголя");

    let (new_run, _, _) = store.groq_prepare_run(meeting, MODELS[0], true, true).unwrap();
    result["protocol_title"] = json!("Подготовка квартального отчёта");
    store.groq_complete(new_run, &result).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    let listed = &workspace["meetings"][0];
    let exported = &store.export(meeting).unwrap()["meeting"];
    for metadata in [listed, exported] {
        assert_eq!(metadata["title"], "Совещание");
        assert_eq!(metadata["display_title"], "Подготовка квартального отчёта");
        assert_eq!(metadata["protocol_title"], "Подготовка квартального отчёта");
        assert_eq!(metadata["project_name"], "Отчётность");
        assert_eq!(metadata["meeting_date"], "2026-11-21");
        assert_eq!(metadata["meeting_at"], "2026-11-21T01:30:00+03:00");
    }
    assert_eq!(store.groq_analysis(meeting).unwrap()["stale"], false);
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Сверка с командой","project_id":project["id"],"participants":[]
    }})).unwrap();
    let exported = &store.export(meeting).unwrap()["meeting"];
    assert_eq!(exported["display_title"], "Сверка с командой");
    assert_eq!(exported["protocol_title"], "Подготовка квартального отчёта");
}

#[test]
fn ollama_profile_persists_and_prepares_analysis_without_cloud_consent() {
    let (dir, store, meeting, _) = setup();
    let path = dir.path().join("db");
    Connection::open(&path).unwrap().execute(
        "INSERT INTO workspace_settings(key,data_json) VALUES('groq',?1)",
        [json!({"model": OLLAMA_MODEL}).to_string()],
    ).unwrap();
    let mut worker = GroqWorker::new(&path, &store).unwrap();
    assert_eq!(worker.status()["local"], true);
    assert_eq!(worker.status()["has_key"], false);
    worker.settings(&store, &json!({"profile":"assistant","local":true})).unwrap();
    worker.settings(&store, &json!({"profile":"live","model":OLLAMA_MODEL})).unwrap();
    let reopened = GroqWorker::new(&path, &store).unwrap();
    assert_eq!(reopened.status()["assistant_local"], true);
    assert_eq!(reopened.status()["assistant_model"], OLLAMA_MODEL);
    assert_eq!(reopened.status()["live_model"], OLLAMA_MODEL);
    assert!(store.groq_prepare(meeting, MODELS[0], false).is_err());
    assert!(store.groq_prepare(meeting, OLLAMA_MODEL, false).is_ok());
}

#[test]
fn assistant_provider_can_differ_from_protocol_provider() {
    let (dir, store, _, _) = setup();
    let path = dir.path().join("db");
    Connection::open(&path).unwrap().execute(
        "INSERT INTO workspace_settings(key,data_json) VALUES('groq',?1)",
        [json!({"model": OLLAMA_MODEL, "assistant_local": true}).to_string()],
    ).unwrap();
    let mut worker = GroqWorker::new(&path, &store).unwrap();
    assert_eq!(worker.status()["assistant_model"], OLLAMA_MODEL);
    let cloud = "deepseek:deepseek-flash";
    worker.settings(&store, &json!({"profile":"assistant","model":cloud})).unwrap();
    worker.settings(&store, &json!({"profile":"live","use_full_profile":true})).unwrap();
    let mut reopened = GroqWorker::new(&path, &store).unwrap();
    assert_eq!(reopened.status()["assistant_model"], cloud);
    assert_eq!(reopened.status()["model"], OLLAMA_MODEL);
    assert!(reopened.settings(&store, &json!({"profile":"assistant","model":"ollama:unknown"})).is_err());
    assert_eq!(reopened.status()["assistant_model"], cloud);
    reopened.settings(&store, &json!({"profile":"assistant","use_full_profile":true})).unwrap();
    assert!(GroqWorker::new(&path, &store).unwrap().status()["assistant_model"].is_null());
}
#[test]
fn analysis_is_atomic_idempotent_and_only_proposes() {
    let (_d, s, m, seg) = setup();
    s.workspace_action(&json!({"op":"save_meeting_notes","meeting_id":m,"revision":0,"summary":"My notes","open_questions":""})).unwrap();
    assert!(s.groq_prepare(m, MODELS[0], false).is_err());
    let (id, input, cached) = s.groq_prepare(m, MODELS[0], true).unwrap();
    assert!(!cached);
    assert_eq!(input["segments"][0]["id"], seg);
    assert!(input["segments"][0].get("sources").is_none());
    let mut result = output(seg);
    result["decisions"][0]["topic"] = json!("  Зона   входа ");
    result["tasks"][0]["topic"] = json!("Закупки");
    s.groq_complete(id, &result).unwrap();
    let w = s.workspace(false, None).unwrap();
    assert_eq!(w["tasks"].as_array().unwrap().len(), 0);
    assert_eq!(w["proposals"].as_array().unwrap().len(), 2);
    assert_eq!(w["decisions"].as_array().unwrap().len(), 0);
    assert_eq!(s.meeting_notes(m).unwrap()["summary"], "My notes");
    assert!(s.groq_prepare(m, MODELS[0], true).unwrap().2);
    assert!(s.groq_complete(id, &output(seg)).is_err());
    assert_eq!(
        s.workspace(false, None).unwrap()["proposals"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let p = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "decision")
        .unwrap();
    s.workspace_action(
        &json!({"op":"review","id":p["id"],"data":{"title":"Confirmed report","project_id":null}}),
    )
    .unwrap();
    assert_eq!(
        s.workspace(false, None).unwrap()["decisions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let task = w["proposals"].as_array().unwrap().iter()
        .find(|proposal| proposal["kind"] == "create_task").unwrap();
    assert_eq!(task["source"]["topic"], "Закупки");
    s.workspace_action(&json!({
        "op":"review", "id":task["id"],
        "data":{"title":"Подготовить отчёт","stage_id":"todo","project_id":null,"priority":"normal","blocked":false}
    })).unwrap();
    let saved = s.workspace(false, None).unwrap();
    assert_eq!(saved["decisions"][0]["source"]["topic"], "Зона входа");
    assert_eq!(saved["tasks"][0]["sources"][0]["topic"], "Закупки");
}
#[test]
fn malformed_or_hallucinated_sources_leave_no_partial_result() {
    let (_d, s, m, seg) = setup();
    let (id, _, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    let mut bad = output(seg);
    bad["tasks"][0]["source_segment_ids"] = json!([9999]);
    assert!(s.groq_complete(id, &bad).is_err());
    assert!(s.workspace(false, None).unwrap()["proposals"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(s.groq_analysis(m).unwrap()["saved"].is_null());
    bad = output(seg);
    bad["tasks"][0]["due_date"] = json!("2026-02-30");
    assert!(s.groq_complete(id, &bad).is_err());
    s.groq_complete(id, &output(seg)).unwrap();
}
#[test]
fn corrected_transcripts_invalidate_summary_but_keep_pending_proposals_reviewable() {
    let (d, s, m, seg) = setup();
    let (id, input, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    s.groq_complete(id, &output(seg)).unwrap();
    let workspace = s.workspace(false, None).unwrap();
    let p = workspace["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "decision")
        .unwrap()["id"]
        .clone();
    let c = Connection::open(d.path().join("db")).unwrap();
    c.execute("INSERT INTO segment_edits(model_run_id,segment_id,text) VALUES (?1,?2,'Do not prepare report')",params![input["model_run_id"].as_i64(),seg]).unwrap();
    assert_eq!(s.groq_analysis(m).unwrap()["stale"], true);
    assert!(s
        .workspace_action(
            &json!({"op":"review","id":p,"data":{"title":"Reviewed original proposal","project_id":null}})
        )
        .is_ok());
    let (newid, _, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    assert_ne!(newid, id);
    c.execute("UPDATE meetings SET title='Changed' WHERE id=?1", [m])
        .unwrap();
    assert!(s.groq_complete(newid, &output(seg)).is_err());
}
#[test]
fn repeated_analysis_deduplicates_and_unknown_owner_is_unassigned() {
    let (_d, s, m, seg) = setup();
    let (id, _, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    let mut v = output(seg);
    v["tasks"][0]["assignee_name"] = json!("Unknown person");
    let item = v["tasks"][0].clone();
    v["tasks"].as_array_mut().unwrap().push(item);
    s.groq_complete(id, &v).unwrap();
    let w = s.workspace(false, None).unwrap();
    let tasks: Vec<_> = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["kind"] == "create_task")
        .collect();
    assert_eq!(tasks.len(), 1);
    assert!(tasks[0]["assignee_id"].is_null());
    assert!(tasks[0]["description"]
        .as_str()
        .unwrap()
        .contains("Unknown person"));
}
#[test]
fn restart_requires_explicit_retry_and_keeps_no_secret_in_database() {
    let (d, s, m, _) = setup();
    let (id, _, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    let worker = GroqWorker::new(&d.path().join("db"), &s).unwrap();
    assert_eq!(worker.status()["has_key"], false);
    assert_eq!(s.groq_analysis(m).unwrap()["state"], "interrupted");
    let (retry, _, cached) = s.groq_prepare(m, MODELS[0], true).unwrap();
    assert_eq!(retry, id);
    assert!(!cached);
}

#[test]
fn uncertain_concrete_actions_are_proposals_with_visible_clarification() {
    let (_d, s, m, seg) = setup();
    let (id, _, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    let mut v = output(seg);
    v["tasks"][0]["needs_clarification"] = json!(true);
    v["tasks"][0]["clarification"] = json!("Confirm who will prepare the report");
    s.groq_complete(id, &v).unwrap();
    let w = s.workspace(false, None).unwrap();
    assert!(w["tasks"].as_array().unwrap().is_empty());
    let proposal = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "create_task")
        .unwrap();
    assert_eq!(proposal["needs_clarification"], true);
    assert_eq!(
        proposal["clarification"],
        "Confirm who will prepare the report"
    );
    assert!(proposal["assignee_id"].is_null());
    assert!(proposal["due_date"].is_null());
}

#[test]
fn malformed_clarification_rolls_back_the_entire_response() {
    let (_d, s, m, seg) = setup();
    let (id, _, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    let mut v = output(seg);
    v["tasks"][0]["needs_clarification"] = json!(true);
    v["tasks"][0]["clarification"] = json!("");
    assert!(s.groq_complete(id, &v).is_err());
    v["tasks"][0]["needs_clarification"] = json!("yes");
    assert!(s.groq_complete(id, &v).is_err());
    assert!(s.workspace(false, None).unwrap()["proposals"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn older_extraction_policy_does_not_cache_an_empty_result_forever() {
    let (d, s, m, seg) = setup();
    let (id, input, _) = s.groq_prepare(m, MODELS[0], true).unwrap();
    let mut empty = output(seg);
    empty["tasks"] = json!([]);
    empty["decisions"] = json!([]);
    s.groq_complete(id, &empty).unwrap();
    let c = Connection::open(d.path().join("db")).unwrap();
    c.execute(
        "UPDATE meeting_analyses SET source_revision='previous-analysis-policy' WHERE id=?1",
        [id],
    )
    .unwrap();
    assert_eq!(s.groq_analysis(m).unwrap()["stale"], true);
    let (new_id, new_input, cached) = s.groq_prepare(m, MODELS[0], true).unwrap();
    assert!(!cached);
    assert_ne!(id, new_id);
    assert_eq!(input["segments"], new_input["segments"]);
    s.groq_complete(new_id, &output(seg)).unwrap();
    assert_eq!(s.groq_analysis(m).unwrap()["stale"], false);
}

#[test]
fn groq_proposal_carries_named_assignee_and_exact_deadline() {
    let (_dir, store, meeting, segment) = setup();
    let person = store.add_person("Анна").unwrap();
    store
        .workspace_action(&json!({
            "op":"save_meeting","id":meeting,
            "data":{"title":"Планирование","participants":[person]}
        }))
        .unwrap();
    let (id, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut result = output(segment);
    let task = &mut result["tasks"][0];
    task["assignee_name"] = json!("анна");
    task["due_date"] = json!("2026-11-05");
    task["due_time"] = json!("17:30");
    store.groq_complete(id, &result).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    let proposal = workspace["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "create_task")
        .unwrap();
    assert_eq!(proposal["assignee_id"], person);
    assert_eq!(proposal["due_date"], "2026-11-05");
    assert_eq!(proposal["due_time"], "17:30");
}

#[test]
fn successful_reanalysis_replaces_pending_proposals_and_archives_drafts() {
    let (_dir, store, meeting, segment) = setup();
    let (first, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let original = output(segment);
    store.groq_complete(first, &original).unwrap();
    let initial = store.workspace(false, None).unwrap();
    let task = initial["proposals"].as_array().unwrap().iter()
        .find(|proposal| proposal["kind"] == "create_task").unwrap();
    let proposal_id = &task["id"];
    let draft = json!({"id":proposal_id,"data":{"title":"Reviewed report","due_date":"2026-11-29"}});
    store.workspace_action(&json!({"op":"save_review_draft","id":proposal_id,"draft":draft})).unwrap();
    let before = store.workspace(false, None).unwrap()["proposals"].clone();
    assert!(before.as_array().unwrap().iter().any(|proposal| proposal["review_draft"] == draft));

    let (second, _, _) = store.groq_prepare_run(meeting, MODELS[0], true, true).unwrap();
    let mut invalid = original.clone();
    invalid["tasks"][0]["source_segment_ids"] = json!([999999]);
    assert!(store.groq_complete(second, &invalid).is_err());
    assert_eq!(store.workspace(false, None).unwrap()["proposals"], before);
    let mut updated = original;
    updated["tasks"][0]["description"] = json!("Different description");
    updated["tasks"][0]["due_date"] = json!("2026-11-30");
    store.groq_complete(second, &updated).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    let old = proposals.iter().find(|p| &p["id"] == proposal_id).unwrap();
    assert_eq!(old["status"], "rejected");
    assert_eq!(old["review_draft"], draft);
    let new = proposals.iter().find(|p| p["kind"] == "create_task" && p["status"] == "pending").unwrap();
    assert_eq!(new["due_date"], "2026-11-30");
    assert!(new["review_draft"].is_null());
    assert_eq!(store.groq_analysis(meeting).unwrap()["stale"], false);
}

#[test]
fn analysis_creates_reviewable_blocking_proposals_and_batch_rolls_back_on_error() {
    let (_dir, store, meeting, segment) = setup();
    let (analysis, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut result = output(segment);
    result["tasks"][0]["kind"] = json!("change_blocked");
    result["tasks"][0]["blocked"] = json!(true);
    result["tasks"][0]["blocked_reason"] = json!("Waiting for materials");
    store.groq_complete(analysis, &result).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    let blocked = proposals.iter().find(|p| p["kind"] == "change_blocked").unwrap();
    let decision = proposals.iter().find(|p| p["kind"] == "decision").unwrap();
    assert_eq!(blocked["proposed"]["blocked_reason"], "Waiting for materials");
    let accept_decision = json!({"id":decision["id"],"data":{"title":"Prepare report"}});
    let invalid = json!({"id":blocked["id"],"data":{"blocked":true,"blocked_reason":"Waiting"}});
    assert!(store.workspace_action(&json!({"op":"review_batch","items":[accept_decision,invalid]})).is_err());
    assert!(store.workspace(false, None).unwrap()["decisions"].as_array().unwrap().is_empty());
    let accepted = store.workspace_action(&json!({"op":"review_batch","items":[accept_decision]})).unwrap();
    assert_eq!(accepted["applied"].as_array().unwrap().len(), 1);
}

#[test]
fn combined_deadline_and_assignment_can_be_applied_to_one_task() {
    let (_dir, store, meeting, segment) = setup();
    let person = store.add_person("Лена").unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,
        "data":{"title":"Планирование","participants":[person]}})).unwrap();
    let task = store.workspace_action(&json!({"op":"save_task",
        "data":{"title":"Prepare report","stage_id":"todo","blocked":false,"priority":"normal"}})).unwrap();
    let (analysis, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut result = output(segment);
    result["tasks"][0]["kind"] = json!("change_due");
    result["tasks"][0]["assignee_name"] = json!("Лена");
    result["tasks"][0]["due_date"] = json!("2026-11-05");
    result["tasks"][0]["due_time"] = json!("15:00");
    store.groq_complete(analysis, &result).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    let due = proposals.iter().find(|p| p["kind"] == "change_due").unwrap();
    let assignee = proposals.iter().find(|p| p["kind"] == "change_assignee").unwrap();
    store.workspace_action(&json!({"op":"review_batch","items":[
        {"id":due["id"],"existing_task_id":task["id"],"task_revision":task["revision"],"data":due["proposed"]},
        {"id":assignee["id"],"existing_task_id":task["id"],"task_revision":task["revision"],"data":assignee["proposed"]}
    ]})).unwrap();
    let updated = store.workspace(false, None).unwrap();
    assert_eq!(updated["tasks"][0]["due_time"], "15:00");
    assert_eq!(updated["tasks"][0]["assignee_id"], person);
}

#[test]
fn late_assignment_reuses_the_task_confirmed_earlier_in_the_meeting() {
    let (dir, store, meeting, segment) = setup();
    let person = store.add_person("Лена").unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,
        "data":{"title":"Планирование","participants":[person]}})).unwrap();
    let (first, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    store.groq_complete(first, &output(segment)).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let create = snapshot["proposals"].as_array().unwrap().iter()
        .find(|proposal| proposal["kind"] == "create_task").unwrap();
    let accepted = store.workspace_action(&json!({"op":"review","id":create["id"],"data":{
        "title":"Prepare report","stage_id":"todo","blocked":false,"priority":"normal"
    }})).unwrap();

    let connection = Connection::open(dir.path().join("db")).unwrap();
    connection.execute(
        "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json)
         SELECT model_run_id,120000,122000,'По отчёту будет Лена','[]' FROM segments WHERE id=?1",
        [segment],
    ).unwrap();
    let late_segment = connection.last_insert_rowid();
    let (second, input, _) = store.groq_prepare(meeting, MODELS[1], true).unwrap();
    assert_eq!(input["discussed_tasks"][0]["title"], "Prepare report");
    let mut result = output(late_segment);
    result["decisions"] = json!([]);
    result["tasks"][0]["kind"] = json!("change_assignee");
    result["tasks"][0]["assignee_name"] = json!("Лена");
    store.groq_complete(second, &result).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let assignment = snapshot["proposals"].as_array().unwrap().iter()
        .find(|proposal| proposal["kind"] == "change_assignee").unwrap();
    assert_eq!(assignment["task_id"], accepted["task"]["id"]);
    assert_eq!(assignment["proposed"]["assignee_id"], person);
    assert_eq!(assignment["source"]["start_ms"], 120000);
    assert_eq!(snapshot["tasks"].as_array().unwrap().len(), 1);
}

#[test]
fn review_combines_pending_purchase_and_deadline_with_an_accepted_decision() {
    let (_dir, store, meeting, _) = setup();
    let person = store.add_person("Давид").unwrap();
    let propose = |kind: &str, title: &str, start_ms: i64| {
        store.workspace_action(&json!({"op":"propose","data":{
            "kind":kind,"title":title,
            "source":{"meeting_id":meeting,"start_ms":start_ms,"quote":title}
        }})).unwrap()["id"].clone()
    };
    let purchase = propose("create_task", "Закупить ткань", 0);
    let deadline = propose("create_task", "Перенести закупку ткани", 5000);
    let decision = propose("decision", "Назначить Давида ответственным", 10000);
    store.workspace_action(&json!({"op":"review","id":decision,
        "data":{"title":"Назначить Давида ответственным"}})).unwrap();

    let result = store.workspace_action(&json!({"op":"review","id":purchase,
        "related_proposal_ids":[deadline,decision],
        "data":{"title":"Закупить ткань","stage_id":"todo","blocked":false,
                "priority":"normal","assignee_id":person,"due_date":"2026-11-24"}
    })).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let task = &result["task"];
    assert_eq!(snapshot["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(task["assignee_id"], person);
    assert_eq!(task["due_date"], "2026-11-24");
    assert_eq!(task["sources"].as_array().unwrap().len(), 3);
    assert_eq!(snapshot["decisions"].as_array().unwrap().len(), 1);
    assert!(snapshot["proposals"].as_array().unwrap().iter()
        .all(|proposal| proposal["status"] == "accepted"));
}

#[test]
fn retranscribing_an_overlapping_excerpt_does_not_reopen_an_accepted_task() {
    let (dir, store, meeting, segment) = setup();
    let conn = Connection::open(dir.path().join("db")).unwrap();
    conn.execute("UPDATE segments SET start_ms=32000,end_ms=35000 WHERE id=?1", [segment]).unwrap();
    let (first, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut initial = output(segment);
    initial["decisions"] = json!([]);
    store.groq_complete(first, &initial).unwrap();
    let proposal = store.workspace(false, None).unwrap()["proposals"][0]["id"].clone();
    let accepted = store.workspace_action(&json!({"op":"review","id":proposal,"data":{
        "title":"Prepare report","stage_id":"todo","blocked":false,"priority":"normal"
    }})).unwrap();

    conn.execute(
        "INSERT INTO processing_jobs(meeting_id,kind,status) VALUES (?1,'transcribe','completed')",
        [meeting],
    ).unwrap();
    let job = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO model_runs(job_id,meeting_id,model_path,model_sha256,engine_path,engine_sha256,language,status,inputs_json)
         VALUES (?1,?2,'fixture',?3,'fixture',?3,'ru','completed','[]')",
        params![job, meeting, "0".repeat(64)],
    ).unwrap();
    let run = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json)
         VALUES (?1,20000,35000,'We still need to prepare the report by Friday','[]')",
        [run],
    ).unwrap();
    let overlapping = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json)
         VALUES (?1,90000,94000,'Prepare a separate report','[]')",
        [run],
    ).unwrap();
    let separate = conn.last_insert_rowid();

    let (second, input, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    assert_eq!(input["model_run_id"], run);
    initial["tasks"][0]["source_segment_ids"] = json!([overlapping]);
    let mut later = initial["tasks"][0].clone();
    later["source_segment_ids"] = json!([separate]);
    initial["tasks"].as_array_mut().unwrap().push(later);
    store.groq_complete(second, &initial).unwrap();

    let snapshot = store.workspace(false, None).unwrap();
    assert_eq!(snapshot["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["tasks"][0]["id"], accepted["task"]["id"]);
    let proposals = snapshot["proposals"].as_array().unwrap();
    assert_eq!(proposals.len(), 2);
    let pending = proposals.iter().find(|item| item["status"] == "pending").unwrap();
    assert_eq!(pending["source"]["segment_ids"], json!([separate]));
}

#[test]
fn continued_meeting_keeps_the_approved_task_and_proposes_only_the_new_deadline() {
    let (dir, store, meeting, opening) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Поставка","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Планирование","project_id":project["id"],"participants":[]
    }})).unwrap();
    let mut response = output(opening);
    response["decisions"] = json!([]);
    response["tasks"][0]["due_date"] = json!("2026-11-24");
    let (analysis, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    store.groq_complete(analysis, &response).unwrap();
    let proposal = store.workspace(false, None).unwrap()["proposals"][0]["id"].clone();
    let approved = store.workspace_action(&json!({"op":"review","id":proposal,"data":{
        "title":"Prepare report","project_id":project["id"],"stage_id":"todo",
        "priority":"normal","blocked":false,"due_date":"2026-11-24"
    }})).unwrap();
    let task = &approved["task"];

    let conn = Connection::open(dir.path().join("db")).unwrap();
    conn.execute(
        "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json)
         SELECT model_run_id,120000,123000,'Move the report to November 27 at 16:30','[]'
         FROM segments WHERE id=?1",
        [opening],
    ).unwrap();
    let continuation = conn.last_insert_rowid();
    response["tasks"].as_array_mut().unwrap().push(json!({
        "kind":"change_due","title":"Prepare report","task_id":task["id"],
        "project_id":project["id"],"description":"","due_date":"2026-11-27",
        "due_time":"16:30","source_segment_ids":[continuation]
    }));
    let (analysis, _, _) = store.groq_prepare_run(meeting, MODELS[0], true, true).unwrap();
    store.groq_complete(analysis, &response).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    assert_eq!(proposals.len(), 2);
    let change = proposals.iter().find(|item| item["status"] == "pending").unwrap();
    assert_eq!(change["kind"], "change_due");
    assert_eq!(change["task_id"], task["id"]);
    assert_eq!(change["source"]["segment_ids"], json!([continuation]));
    assert_eq!(snapshot["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["tasks"][0]["revision"], task["revision"]);
    assert_eq!(snapshot["tasks"][0]["due_date"], "2026-11-24");
    store.workspace_action(&json!({"op":"review","id":change["id"],"existing_task_id":task["id"],
        "task_revision":task["revision"],"data":change["proposed"]
    })).unwrap();

    let (analysis, _, _) = store.groq_prepare_run(meeting, MODELS[0], true, true).unwrap();
    store.groq_complete(analysis, &response).unwrap();
    let final_state = store.workspace(false, None).unwrap();
    assert_eq!(final_state["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(final_state["tasks"][0]["id"], task["id"]);
    assert_eq!(final_state["tasks"][0]["due_date"], "2026-11-27");
    assert_eq!(final_state["tasks"][0]["due_time"], "16:30");
    assert!(final_state["proposals"].as_array().unwrap().iter().all(|item| item["status"] == "accepted"));
}

#[test]
fn protocol_refinement_can_extend_the_confirmed_task_without_creating_another() {
    let (_dir, store, meeting, segment) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Оформление","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Подготовка","project_id":project["id"],"participants":[]
    }})).unwrap();
    let description = "Проверить исходные материалы.";
    let detail = "Согласовать способ крепления.";
    let (initial_run, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let first = json!({"summary":"Обсудили оформление","open_questions":[],"decisions":[],"tasks":[
        {"title":"Решить вопрос со световиками","description":description,"source_segment_ids":[segment]}
    ]});
    store.groq_complete(initial_run, &first).unwrap();
    let initial = store.workspace(false, None).unwrap();
    store.workspace_action(&json!({"op":"review","id":initial["proposals"][0]["id"],
        "data":{"title":"Решить вопрос со световиками","description":description,"project_id":project["id"],
            "stage_id":"todo","priority":"normal","blocked":false}
    })).unwrap();
    let (next_run, _, _) = store.groq_prepare_run(meeting, MODELS[0], true, true).unwrap();
    let refined = json!({"summary":"Обсудили оформление","open_questions":[],"decisions":[],"tasks":[
        {"title":"Решить со световиками, как вешать панели","description":detail,"source_segment_ids":[segment]},
        {"title":"Заказать ткань для штор","description":"Другая работа","source_segment_ids":[segment]}
    ]});
    store.groq_complete(next_run, &refined).unwrap();
    let pending = store.workspace(false, None).unwrap();
    let task = &pending["tasks"][0];
    let proposals = pending["proposals"].as_array().unwrap();
    let suggestion = proposals.iter().find(|item| item["description"] == detail).unwrap();
    let separate = proposals.iter().find(|item| item["description"] == "Другая работа").unwrap();
    assert_eq!(suggestion["suggested_existing_task_id"], task["id"]);
    assert!(separate["suggested_existing_task_id"].is_null());
    let mut review = json!({"op":"review","id":suggestion["id"],"existing_task_id":task["id"],
        "task_revision":0,"apply_description":true,"data":{"description":detail}});
    assert!(store.workspace_action(&review).is_err());
    review["task_revision"] = task["revision"].clone();
    store.workspace_action(&review).unwrap();
    let complete = store.workspace(false,None).unwrap();
    assert_eq!(complete["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(complete["tasks"][0]["id"], task["id"]);
    assert_eq!(complete["tasks"][0]["description"], format!("{description}\n\n{detail}"));
    assert_eq!(complete["tasks"][0]["sources"].as_array().unwrap().len(), 2);
}

#[test]
fn purchases_with_different_purposes_survive_reanalysis() {
    let (_dir, store, meeting, segment) = setup();
    let (first, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut result = output(segment);
    result["tasks"][0]["title"] = json!("Закупить ткань для штор");
    store.groq_complete(first, &result).unwrap();

    let (second, _, _) = store.groq_prepare(meeting, MODELS[1], true).unwrap();
    for title in ["Закупить ткань для столов", "Закупить ткань для драпировки"] {
        let mut task = result["tasks"][0].clone();
        task["title"] = json!(title);
        result["tasks"].as_array_mut().unwrap().push(task);
    }
    store.groq_complete(second, &result).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    assert_eq!(snapshot["proposals"].as_array().unwrap().iter()
        .filter(|proposal| proposal["kind"] == "create_task" && proposal["status"] == "pending").count(), 3);
}

#[test]
fn project_task_changes_are_approved_together_and_inform_the_next_meeting() {
    let (dir, store, meeting, segment) = setup();
    let conn = Connection::open(dir.path().join("db")).unwrap();
    conn.execute("UPDATE segments SET text='Закупку ткани перенести на 24 ноября' WHERE id=?1", [segment]).unwrap();
    conn.execute("INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json)
        SELECT model_run_id,3000,5000,'Давид закупит ткань','[]' FROM segments WHERE id=?1", [segment]).unwrap();
    let assignment_segment = conn.last_insert_rowid();
    let person = store.add_person("Давид").unwrap();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Тенты","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Планирование","project_id":project["id"],"participants":[]
    }})).unwrap();
    let task = store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Закупить ткань","project_id":project["id"],"stage_id":"todo",
        "priority":"normal","blocked":false,"due_date":"2026-11-30"
    }})).unwrap();
    let (analysis, input, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    assert_eq!(input["project_tasks"][0]["id"], task["id"]);
    assert_eq!(input["project_tasks"][0]["due_date"], "2026-11-30");
    assert_eq!(input["participants"], json!([]));
    let mut result = output(segment);
    result["decisions"] = json!([]);
    result["tasks"][0]["kind"] = json!("change_due");
    result["tasks"][0]["title"] = json!("Перенести закупку ткани");
    result["tasks"][0]["task_id"] = task["id"].clone();
    result["tasks"][0]["due_date"] = json!("2026-11-24");
    let mut assignment = result["tasks"][0].clone();
    assignment["kind"] = json!("change_assignee");
    assignment["due_date"] = Value::Null;
    assignment["assignee_name"] = json!("Давид");
    assignment["source_segment_ids"] = json!([assignment_segment]);
    result["tasks"].as_array_mut().unwrap().push(assignment);
    store.groq_complete(analysis, &result).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    assert_eq!(proposals.len(), 1);
    let change = &proposals[0];
    assert_eq!(change["kind"], "change_task");
    assert_eq!(change["task_id"], task["id"]);
    assert_eq!(change["title"], "Закупить ткань");
    assert_eq!(change["source"]["segment_ids"], json!([segment,assignment_segment]));
    assert_eq!(change["proposed"]["assignee_id"], person);
    assert_eq!(snapshot["tasks"][0]["due_date"], "2026-11-30");

    let mut edit = task.clone();
    edit["due_date"] = json!("2026-11-26");
    let edited = store.workspace_action(&json!({"op":"save_task","id":task["id"],"revision":task["revision"],"data":edit})).unwrap();
    let mut approval = json!({
        "op":"review","id":change["id"],"existing_task_id":task["id"],
        "task_revision":edited["revision"],"data":change["proposed"]
    });
    assert!(store.workspace_action(&approval).unwrap_err().to_string().contains("после анализа"));
    assert_eq!(store.workspace(false, None).unwrap()["decisions"], json!([]));
    approval["acknowledge_task_conflict"] = json!(true);
    let applied = store.workspace_action(&approval).unwrap();
    assert_eq!(applied["task"]["id"], task["id"]);
    assert_eq!(applied["task"]["due_date"], "2026-11-24");
    assert_eq!(applied["task"]["assignee_id"], person);
    assert_eq!(applied["task"]["stage_id"], task["stage_id"]);
    assert!(store.workspace_action(&approval).is_err());
    let snapshot = store.workspace(false, None).unwrap();
    assert_eq!(snapshot["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(snapshot["decisions"].as_array().unwrap().len(), 1);
    let decision = &snapshot["decisions"][0];
    assert_eq!(decision["source"]["task_id"], task["id"]);
    assert_eq!(applied["task"]["sources"][0]["decision_id"], decision["id"]);
    let history: String = conn.query_row(
        "SELECT previous_json FROM change_events WHERE entity_type='tasks' AND entity_id=?1 ORDER BY id DESC LIMIT 1",
        [task["id"].as_i64()], |row| row.get(0)).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&history).unwrap()["due_date"], "2026-11-26");

    let (rerun, _, _) = store.groq_prepare_run(meeting, MODELS[0], true, true).unwrap();
    store.groq_complete(rerun, &result).unwrap();
    assert_eq!(store.workspace(false, None).unwrap()["proposals"].as_array().unwrap().len(), 1);

    let (follow_up, follow_up_segment) = meeting_with_transcript(&store, &conn,
        "Продолжение работ", "Поставщик ткани не успевает, закупка заблокирована");
    store.workspace_action(&json!({"op":"save_meeting","id":follow_up,"data":{
        "title":"Продолжение работ","project_id":project["id"],"participants":[]
    }})).unwrap();
    let (analysis, input, _) = store.groq_prepare(follow_up, MODELS[0], true).unwrap();
    assert_eq!(input["project_tasks"][0]["due_date"], "2026-11-24");
    assert_eq!(input["project_decisions"][0]["task_id"], task["id"]);
    let mut follow_up_result = output(follow_up_segment);
    follow_up_result["decisions"] = json!([]);
    follow_up_result["tasks"][0]["kind"] = json!("change_blocked");
    follow_up_result["tasks"][0]["title"] = json!("Закупить ткань");
    follow_up_result["tasks"][0]["blocked"] = json!(true);
    follow_up_result["tasks"][0]["blocked_reason"] = json!("Поставщик не успевает");
    store.groq_complete(analysis, &follow_up_result).unwrap();
    let state = store.workspace(false, None).unwrap();
    let blocker = state["proposals"].as_array().unwrap().iter().find(|p| p["kind"] == "change_blocked").unwrap();
    assert_eq!(blocker["task_id"], task["id"]);
    assert_eq!(state["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(state["tasks"][0]["blocked"], false);

    let other = store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Закупить ткань для скатертей","project_id":project["id"],"stage_id":"todo",
        "priority":"normal","blocked":false
    }})).unwrap();
    let (analysis, _, _) = store.groq_prepare_run(follow_up, MODELS[0], true, true).unwrap();
    follow_up_result["tasks"][0]["needs_clarification"] = json!(true);
    follow_up_result["tasks"][0]["clarification"] = json!("Для какой закупки установлена блокировка?");
    store.groq_complete(analysis, &follow_up_result).unwrap();
    let state = store.workspace(false, None).unwrap();
    let ambiguous = state["proposals"].as_array().unwrap().iter()
        .find(|p| p["kind"] == "change_blocked" && p["status"] == "pending").unwrap();
    assert!(ambiguous["task_id"].is_null());
    let choices = ambiguous["candidate_task_ids"].as_array().unwrap();
    assert!(choices.contains(&task["id"]));
    assert!(choices.contains(&other["id"]));
}

#[test]
fn single_change_checks_only_its_own_fields_against_the_analysis_snapshot() {
    let (_dir, store, meeting, segment) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Reports","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Planning","project_id":project["id"],"participants":[]
    }})).unwrap();
    let original = store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Prepare report","project_id":project["id"],"stage_id":"todo",
        "priority":"normal","blocked":false,"due_date":"2026-11-30"
    }})).unwrap();
    let (analysis, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let mut result = output(segment);
    result["decisions"] = json!([]);
    result["tasks"][0]["kind"] = json!("change_blocked");
    result["tasks"][0]["task_id"] = original["id"].clone();
    result["tasks"][0]["blocked"] = json!(true);
    result["tasks"][0]["blocked_reason"] = json!("Waiting for figures");
    let mut status = result["tasks"][0].clone();
    status["kind"] = json!("change_status");
    status["stage_title"] = json!("На проверке");
    result["tasks"].as_array_mut().unwrap().push(status);
    store.groq_complete(analysis, &result).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    let proposals = workspace["proposals"].as_array().unwrap();
    let blocker = proposals.iter().find(|item| item["kind"] == "change_blocked").unwrap();
    let status = proposals.iter().find(|item| item["kind"] == "change_status").unwrap();
    assert_eq!(blocker["base_task"]["blocked"], false);
    assert_eq!(status["base_task"]["stage_id"], "todo");

    let mut manual_edit = original.clone();
    manual_edit["stage_id"] = json!("doing");
    let edited = store.workspace_action(&json!({"op":"save_task","id":original["id"],
        "revision":original["revision"],"data":manual_edit})).unwrap();
    let blocked = store.workspace_action(&json!({"op":"review","id":blocker["id"],
        "task_revision":edited["revision"],"data":blocker["proposed"]})).unwrap();
    assert_eq!(blocked["task"]["stage_id"], "doing");
    assert_eq!(blocked["task"]["sources"][0]["proposal_id"], blocker["id"]);

    let mut approval = json!({"op":"review","id":status["id"],
        "task_revision":blocked["task"]["revision"],"data":{"stage_id":"review"}});
    let error = store.workspace_action(&approval).unwrap_err().to_string();
    assert!(error.contains("после анализа"), "{error}");
    approval["acknowledge_task_conflict"] = json!(true);
    let applied = store.workspace_action(&approval).unwrap();
    assert_eq!(applied["task"]["stage_id"], "review");
    assert_eq!(applied["task"]["blocked_reason"], "Waiting for figures");
}

#[test]
fn one_approval_links_a_decision_to_two_task_changes_and_keeps_replacements() {
    let (_dir, store, meeting, _) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Supplies","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    let source = json!({"meeting_id":meeting,"start_ms":0,"quote":"Both orders move to Friday"});
    let decision = store.workspace_action(&json!({"op":"propose","data":{
        "kind":"decision","title":"Move orders","project_id":project["id"],"source":source
    }})).unwrap();
    let mut items = Vec::new();
    let mut task_ids = Vec::new();
    for title in ["Order fabric", "Order packaging"] {
        let task = store.workspace_action(&json!({"op":"save_task","data":{
            "title":title,"project_id":project["id"],"stage_id":"todo","priority":"normal","blocked":false
        }})).unwrap();
        task_ids.push(task["id"].clone());
        let proposal = store.workspace_action(&json!({"op":"propose","data":{
            "kind":"change_due","task_id":task["id"],"title":title,"project_id":project["id"],"source":source
        }})).unwrap();
        items.push(json!({"id":proposal["id"],"existing_task_id":task["id"],
            "task_revision":task["revision"],"data":{"due_date":"2026-11-27"}}));
    }
    items.push(json!({"id":decision["id"],"data":{
        "title":"Move both orders to Friday","project_id":project["id"],"reason":"Supplier requested more time"
    }}));
    store.workspace_action(&json!({"op":"review_batch","associate_decision":true,"items":items})).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    let previous = &workspace["decisions"][0];
    assert_eq!(previous["task_ids"], json!(task_ids));
    assert_eq!(previous["reason"], "Supplier requested more time");
    for task in workspace["tasks"].as_array().unwrap() {
        assert_eq!(task["due_date"], "2026-11-27");
        assert_eq!(task["sources"][0]["decision_id"], previous["id"]);
    }
    let new = store.workspace_action(&json!({"op":"save_project_decision","project_id":project["id"],
        "text":"Confirm supplier alternatives","supersedes_id":previous["id"],"task_ids":task_ids
    })).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    assert_eq!(workspace["decisions"][0]["supersedes_id"], previous["id"]);
    assert_eq!(workspace["decisions"][1]["status"], "superseded");
    store.workspace_action(&json!({"op":"cancel_decision","id":new["id"]})).unwrap();
    assert_eq!(store.workspace(false, None).unwrap()["decisions"][0]["status"], "cancelled");
}

#[test]
fn local_analysis_resolves_an_explicit_task_without_an_api_key() {
    let (dir, store, meeting, segment) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Supplies","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,
        "data":{"title":"Planning","project_id":project["id"],"participants":[]}})).unwrap();
    let task = store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Order fabric","project_id":project["id"],"stage_id":"todo","priority":"normal","blocked":false
    }})).unwrap();
    let database = dir.path().join("db");
    let connection = Connection::open(&database).unwrap();
    connection.execute("UPDATE segments SET text=?1 WHERE id=?2",
        params![format!("По задаче #{}: перенести срок на 2030-11-24.", task["id"]),segment]).unwrap();
    let mut worker = GroqWorker::new(&database, &store).unwrap();
    let request = json!({"meeting_id":meeting,"local":true});
    let first = worker.start(&store, &request).unwrap();
    assert_eq!(first["cached"], false);
    assert_eq!(worker.start(&store, &request).unwrap()["cached"], true);
    let workspace = store.workspace(false, None).unwrap();
    assert!(workspace["tasks"][0]["due_date"].is_null());
    assert_eq!(workspace["proposals"][0]["proposed"]["due_date"], "2030-11-24");
    assert_eq!(workspace["proposals"][0]["task_id"], task["id"]);
    assert_eq!(workspace["proposals"][0]["origin"], "local_analysis");
    let findings = &store.groq_analysis(meeting).unwrap()["saved"]["result"]["findings"];
    assert_eq!(findings[0]["source"]["segment_ids"], json!([segment]));
    assert_eq!(store.ai_budget(None).unwrap()["today_tokens"], 0);
}

#[test]
fn assistant_chat_commands_stage_local_changes_until_approval() {
    let (_dir, store, _, _) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Тенты","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    let task = store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Закупить ткань","project_id":project["id"],"stage_id":"todo","priority":"normal","blocked":false
    }})).unwrap();
    let id = task["id"].as_i64().unwrap();
    let stage = |action: &str| store.workspace_action(&json!({
        "op":"assistant_command","text":format!("По задаче #{id}: {action}")
    }));
    let contextual = json!({"op":"assistant_command","task_id":id,"text":"Перенеси срок на 2030-11-24 в 16:30"});
    let first = store.workspace_action(&contextual).unwrap();
    assert_eq!(store.workspace_action(&contextual).unwrap(), first);
    let change = store.workspace(false, None).unwrap();
    assert_eq!(change["proposals"].as_array().unwrap().len(), 1);
    assert!(change["tasks"][0]["due_date"].is_null());
    let proposal = &change["proposals"][0];
    let result = store.workspace_action(&json!({"op":"review","id":proposal["id"],
        "task_revision":task["revision"],"data":proposal["proposed"]
    })).unwrap();
    assert_eq!(result["task"]["due_time"], "16:30");
    assert_eq!(result["task"]["sources"][0]["type"], "assistant_command");
    assert_eq!(result["task"]["sources"][0]["quote"], contextual["text"]);
    assert!(stage("перенести срок на 2030-11-24 в 16:30").is_err());
    let davyd = store.add_person("Давид").unwrap();
    let update = json!({"op":"assistant_command","task_id":id,
        "text":"Пусть Давид займётся тканью ко второму декабря",
        "changes":{"due_date":"2030-12-02","assignee":"Давид"}});
    let invalid = json!({"changes":{"due_date":"2030-02-30","assignee":"Давид"}});
    let mut malformed = update.clone();
    malformed["changes"] = invalid["changes"].clone();
    assert!(store.workspace_action(&malformed).is_err());
    let change = store.workspace_action(&update).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    assert_eq!(snapshot["tasks"][0]["due_date"], "2030-11-24");
    let staged = snapshot["proposals"].as_array().unwrap().iter()
        .find(|proposal| proposal["id"] == change["id"]).unwrap();
    assert_eq!(staged["source"]["quote"], update["text"]);
    assert_eq!(staged["proposed"]["due_date"], "2030-12-02");
    assert_eq!(staged["proposed"]["assignee_id"], davyd);
    let follow_up = stage("создать связанную задачу: Проверить склад").unwrap();
    let result = store.workspace_action(&json!({"op":"review","id":follow_up["id"],"data":{
        "title":"Проверить склад","project_id":project["id"],
        "stage_id":"todo","priority":"normal","blocked":false
    }})).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let linked = snapshot["tasks"].as_array().unwrap().iter()
        .find(|task| task["id"] == result["task"]["id"]).unwrap();
    assert_eq!(linked["related_task_ids"], json!([id]));
    assert_eq!(store.ai_budget(None).unwrap()["today_tokens"], 0);
}

#[test]
fn assistant_edits_pending_task_deadline_and_assignee_in_the_same_draft() {
    let (_dir, store, meeting, _) = setup();
    let person = store.add_person("Давид").unwrap();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Будущие проекты","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    let proposal = store.workspace_action(&json!({"op":"propose","data":{
        "kind":"create_task","title":"Спросить Охана про сетку","project_id":project["id"],
        "source":{"meeting_id":meeting,"start_ms":0,"quote":"Спросить Охана про сетку"}
    }})).unwrap();
    let command = json!({"op":"assistant_command","proposal_id":proposal["id"],
        "text":"Поставь срок на 1 декабря 2099 Давиду"});
    assert_eq!(store.workspace_action(&command).unwrap(), proposal);
    assert_eq!(store.workspace_action(&command).unwrap(), proposal);
    let correction = json!({"op":"assistant_command","proposal_id":proposal["id"],
        "text":"Только на второе декабря", "changes":{"due_date":"2099-12-02"}});
    assert_eq!(store.workspace_action(&correction).unwrap(), proposal);
    let snapshot = store.workspace(false, None).unwrap();
    assert!(snapshot["tasks"].as_array().unwrap().is_empty());
    assert_eq!(snapshot["proposals"].as_array().unwrap().len(), 1);
    let pending = &snapshot["proposals"][0];
    assert_eq!(pending["status"], "pending");
    assert_eq!(pending["source"]["quote"], "Спросить Охана про сетку");
    let draft = &pending["review_draft"];
    assert_eq!(draft["data"]["due_date"], "2099-12-02");
    assert_eq!(draft["data"]["assignee_id"], person);
    let approved = store.workspace_action(draft).unwrap();
    assert_eq!(approved["task"]["due_date"], "2099-12-02");
    assert_eq!(approved["task"]["assignee_id"], person);
    assert!(store.workspace_action(&command).is_err());
    assert_eq!(store.ai_budget(None).unwrap()["today_tokens"], 0);
}

#[test]
fn local_commands_carry_task_changes_across_two_meetings_without_spending_tokens() {
    let (dir, store, first_meeting, opening) = setup();
    let database = dir.path().join("db");
    let conn = Connection::open(&database).unwrap();
    let person = store.add_person("Давид").unwrap();
    let project = |name: &str| store.workspace_action(&json!({"op":"save_project","data":{
        "title":name,"status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap()["id"].as_i64().unwrap();
    let tents = project("Тенты");
    let stage = project("Сцена");
    let task = |project| store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Закупить ткань","project_id":project,"stage_id":"todo","priority":"normal",
        "blocked":false,"due_date":"2030-11-30"
    }})).unwrap();
    let purchase = task(tents);
    let unrelated = task(stage);
    let assign_project = |meeting| {
        store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
            "title":"Планирование поставки","project_id":tents,"participants":[person]
        }})).unwrap();
    };
    let append_segment = |opening, start: i64, line: String| {
        conn.execute(
            "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json)
             SELECT model_run_id,?2,?2+2000,?3,'[]' FROM segments WHERE id=?1",
            params![opening,start,line],
        ).unwrap();
        conn.last_insert_rowid()
    };

    assign_project(first_meeting);
    let id = purchase["id"].as_i64().unwrap();
    conn.execute("UPDATE segments SET text=?2 WHERE id=?1",
        params![opening, format!("По задаче #{id}: перенести срок на 24 ноября 2030 в 16:30.")]).unwrap();
    let assignment = append_segment(opening, 4000, format!("По задаче #{id}: назначить Давид."));
    append_segment(opening, 8000, format!("По задаче #{}: заблокировать: вне проекта", unrelated["id"]));
    append_segment(opening, 12000, format!("По задаче #{id}: срок до 2030-11-25 в 25:00"));
    let mut worker = GroqWorker::new(&database, &store).unwrap();
    let request = json!({"meeting_id":first_meeting,"local":true});
    assert_eq!(worker.start(&store, &request).unwrap()["local"], true);
    assert_eq!(worker.start(&store, &request).unwrap()["cached"], true);
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    assert_eq!(proposals.len(), 1);
    let combined = &proposals[0];
    assert_eq!(combined["kind"], "change_task");
    assert_eq!(combined["task_id"], id);
    assert_eq!(combined["source"]["segment_ids"], json!([opening, assignment]));
    let approved = store.workspace_action(&json!({"op":"review","id":combined["id"],
        "task_revision":purchase["revision"],"data":combined["proposed"]
    })).unwrap();
    assert_eq!(approved["task"]["due_date"], "2030-11-24");
    assert_eq!(approved["task"]["due_time"], "16:30");
    assert_eq!(approved["task"]["assignee_id"], person);
    assert!(approved["decision_id"].is_number());

    let (second, opening) = meeting_with_transcript(&store, &conn, "Проверка поставки",
        &format!("По задаче #{id}: заблокировать: Поставщик не успевает"));
    assign_project(second);
    let follow_up = append_segment(opening, 4000, format!(
        "По задаче #{id}: создать связанную задачу: Проверить остатки ткани на складе"
    ));
    let context = store.groq_snapshot(second).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    assert_eq!(snapshot["decisions"][0]["id"], approved["decision_id"]);
    assert_eq!(context["project_decisions"][0]["text"], snapshot["decisions"][0]["text"]);
    assert_eq!(context["project_decisions"][0]["task_id"], id);
    assert_eq!(context["project_tasks"][0]["due_time"], "16:30");
    let request = json!({"meeting_id":second,"local":true});
    assert_eq!(worker.start(&store, &request).unwrap()["cached"], false);
    assert_eq!(worker.start(&store, &request).unwrap()["cached"], true);
    let snapshot = store.workspace(false, None).unwrap();
    let proposals = snapshot["proposals"].as_array().unwrap();
    assert_eq!(proposals.iter().filter(|item| item["status"] == "pending").count(), 2);
    let blocker = proposals.iter().find(|item| item["kind"] == "change_blocked").unwrap();
    let linked = proposals.iter().find(|item| item["kind"] == "create_task").unwrap();
    assert_eq!(blocker["task_id"], id);
    assert_eq!(linked["related_task_id"], id);
    assert_eq!(linked["source"]["segment_ids"], json!([follow_up]));
    let applied = store.workspace_action(&json!({"op":"review_batch","items":[
        {"id":blocker["id"],"task_revision":approved["task"]["revision"],"data":blocker["proposed"]},
        {"id":linked["id"],"data":{"title":linked["title"],"project_id":tents,
            "stage_id":"todo","priority":"normal","blocked":false}}
    ]})).unwrap();
    let warehouse = &applied["applied"][1]["task"];
    worker.start(&store, &request).unwrap();
    let final_state = store.workspace(false, None).unwrap();
    assert!(final_state["proposals"].as_array().unwrap().iter().all(|item| item["status"] == "accepted"));
    let tasks = final_state["tasks"].as_array().unwrap();
    assert_eq!(tasks.len(), 3);
    let original = tasks.iter().find(|task| task["id"] == id).unwrap();
    assert_eq!(original["related_task_ids"], json!([warehouse["id"]]));
    assert_eq!(original["blocked_reason"], "Поставщик не успевает");
    let other = tasks.iter().find(|task| task["id"] == unrelated["id"]).unwrap();
    assert_eq!(other["due_date"], "2030-11-30");
    assert_eq!(other["blocked"], false);
    assert_eq!(store.ai_budget(None).unwrap()["today_tokens"], 0);
    assert_eq!(conn.query_row("SELECT count(*) FROM ai_usage", [], |row| row.get::<_,i64>(0)).unwrap(), 0);
}

#[test]
fn model_uncertainty_does_not_assign_a_task_to_the_only_selected_project() {
    let (_dir, store, meeting, segment) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Тенты","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Тенты","project_id":project["id"],"participants":[]
    }})).unwrap();
    let (id, _, _) = store.groq_prepare_projects(meeting, MODELS[0], true, false, &[], false).unwrap();
    let mut result = output(segment);
    result["tasks"][0]["needs_project_clarification"] = json!(true);
    result["tasks"][0]["project_id"] = project["id"].clone();
    store.groq_complete(id, &result).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    let proposal = workspace["proposals"].as_array().unwrap().iter()
        .find(|item| item["kind"] == "create_task").unwrap();
    assert!(proposal["project_id"].is_null());
    assert_eq!(proposal["project_required"], true);
    assert_eq!(proposal["needs_clarification"], true);
}

#[test]
fn multi_project_meetings_keep_scope_follow_up_links_and_review_drafts() {
    let (dir, store, first_meeting, segment) = setup();
    let recipient = store.add_person("Давид").unwrap();
    store.workspace_action(&json!({"op":"settings","data":{"me_id":recipient}})).unwrap();
    let project = |title| store.workspace_action(&json!({"op":"save_project","data":{
        "title":title,"status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap()["id"].as_i64().unwrap();
    let tents = project("Тенты");
    let stage = project("Сцена");
    let unselected = project("Отдельный проект");
    let task = |project_id| store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Закупить ткань","project_id":project_id,"stage_id":"todo","priority":"normal","blocked":false
    }})).unwrap();
    let tent_task = task(tents);
    let stage_task = task(stage);
    let private_task = task(unselected);
    store.workspace_action(&json!({"op":"save_meeting","id":first_meeting,"data":{
        "title":"Тенты и сцена","project_id":tents,"participants":[]
    }})).unwrap();
    assert!(store.groq_prepare_projects(first_meeting, MODELS[0], false, false, &[stage], false).is_err());
    let (analysis, snapshot, _) = store.groq_prepare_projects(first_meeting, MODELS[0], true, false, &[stage], false).unwrap();
    assert_eq!(snapshot["analysis_projects"][1]["id"], stage);
    assert_eq!(snapshot["project_tasks"].as_array().unwrap().len(), 2);
    let mut response = output(segment);
    response["decisions"] = json!([]);
    response["tasks"] = json!([
        {"kind":"change_due","title":"Закупить ткань","description":"","task_id":tent_task["id"],
         "project_id":tents,"due_date":"2026-11-24","source_segment_ids":[segment]},
        {"kind":"create_task","title":"Проверить остатки на складе","description":"","related_task_id":stage_task["id"],
         "project_id":stage,"assignee_name":"Давид","source_segment_ids":[segment]},
        {"kind":"change_due","title":"Закупить ткань","description":"","task_id":private_task["id"],
         "project_id":unselected,"due_date":"2026-11-25","source_segment_ids":[segment]},
        {"kind":"create_task","title":"Подготовить отчёт","description":"","source_segment_ids":[segment]}
    ]);
    store.groq_complete(analysis, &response).unwrap();
    let workspace = store.workspace(false, None).unwrap();
    let proposals = workspace["proposals"].as_array().unwrap();
    let due = proposals.iter().find(|item| item["task_id"] == tent_task["id"]).unwrap();
    assert_eq!(due["project_id"], tents);
    let unknown = proposals.iter().find(|item| item["due_date"] == "2026-11-25").unwrap();
    assert!(unknown["project_id"].is_null() && unknown["task_id"].is_null());
    assert_eq!(unknown["needs_clarification"], true);
    let unassigned_project = proposals.iter().find(|item| item["title"] == "Подготовить отчёт").unwrap();
    assert!(store.workspace_action(&json!({"op":"review","id":unassigned_project["id"],"data":{
        "title":"Подготовить отчёт","stage_id":"todo","priority":"normal","blocked":false
    }})).is_err());

    let followup = proposals.iter().find(|item| item["related_task_id"] == stage_task["id"]).unwrap();
    assert_eq!(followup["project_id"], stage);
    let draft = json!({"id":followup["id"],"data":{"title":"Проверить ткань на складе","project_id":stage}});
    store.workspace_action(&json!({"op":"save_review_draft","id":followup["id"],"draft":draft})).unwrap();
    let (same, _, cached) = store.groq_prepare_projects(first_meeting, MODELS[0], true, false, &[stage], false).unwrap();
    assert_eq!(same, analysis);
    assert!(cached);
    let (fresh, _, _) = store.groq_prepare_projects(first_meeting, MODELS[0], true, true, &[stage], false).unwrap();
    store.groq_complete(fresh, &response).unwrap();
    let current = store.workspace(false, None).unwrap();
    assert_eq!(current["proposals"].as_array().unwrap().iter()
        .find(|item| item["id"] == followup["id"]).unwrap()["review_draft"], draft);
    assert_eq!(current["notifications"], json!([]));
    let (one_project, _, _) = store.groq_prepare_projects(first_meeting, MODELS[0], true, true, &[], false).unwrap();
    let mut narrower_response = response.clone();
    narrower_response["tasks"] = json!([response["tasks"][0]]);
    store.groq_complete(one_project, &narrower_response).unwrap();
    let current = store.workspace(false,None).unwrap();
    let preserved = current["proposals"].as_array().unwrap().iter()
        .find(|item| item["id"] == followup["id"]).unwrap();
    assert_eq!(preserved["status"], "pending");
    assert_eq!(preserved["review_draft"], draft);
    let approval = json!({"op":"review","id":followup["id"],"data":{
        "title":"Проверить остатки на складе","project_id":stage,"assignee_id":recipient,
        "stage_id":"todo","priority":"normal","blocked":false
    }});
    let applied = store.workspace_action(&approval).unwrap();
    let followup_id = &applied["task"]["id"];
    assert!(store.workspace_action(&approval).is_err());
    let state = store.workspace(false, None).unwrap();
    assert_eq!(state["notifications"].as_array().unwrap().len(), 1);
    assert_eq!(&state["notifications"][0]["task_id"], followup_id);
    store.workspace_action(&json!({"op":"read_task_notification","id":state["notifications"][0]["id"]})).unwrap();
    assert!(store.workspace(false, None).unwrap()["notifications"][0]["read_at"].is_string());
    assert_eq!(state["tasks"].as_array().unwrap().iter().find(|task| task["id"] == stage_task["id"]).unwrap()["related_task_ids"],
        json!([followup_id]));

    let conn = Connection::open(dir.path().join("db")).unwrap();
    let (second, _) = meeting_with_transcript(&store, &conn, "Склад", "Сверили остатки ткани");
    store.workspace_action(&json!({"op":"save_meeting","id":second,"data":{
        "title":"Склад","project_id":stage,"participants":[]
    }})).unwrap();
    let context = store.groq_snapshot(second).unwrap();
    let original = context["project_tasks"].as_array().unwrap().iter().find(|task| task["id"] == stage_task["id"]).unwrap();
    assert_eq!(original["related_task_ids"], json!([followup_id]));
    assert_eq!(state["tasks"].as_array().unwrap().iter().find(|task| task["id"] == private_task["id"]).unwrap()["due_date"], Value::Null);
}

#[test]
fn material_links_require_opt_in_and_exclude_url_parameters() {
    let (_dir, store, meeting, segment) = setup();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Материалы","status":"active","stages":vtracker::workspace::default_stages(),
        "materials":"Смета ткани https://example.test/fabric?signature=synthetic#preview\nЗакрытый каталог https://user:pass@example.test/private\nТолько внутренний комментарий"
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Смета ткани","project_id":project["id"],"participants":[]
    }})).unwrap();
    let original = store.workspace_action(&json!({"op":"save_task","data":{
        "title":"Согласовать смету","project_id":project["id"],"stage_id":"todo",
        "priority":"normal","blocked":false,"due_date":"2026-11-30"
    }})).unwrap();
    let mut changed = original.clone();
    changed["due_date"] = json!("2026-11-24");
    store.workspace_action(&json!({"op":"save_task","id":original["id"],"revision":original["revision"],"data":changed})).unwrap();
    let default = store.groq_snapshot(meeting).unwrap();
    assert_eq!(default["project_materials"],json!([]));
    assert_eq!(default["project_tasks"][0]["recent_change"]["due_date"],json!({"before":"2026-11-30","after":"2026-11-24"}));
    let (analysis, shared, _) = store.groq_prepare_projects(meeting,MODELS[0],true,false,&[],true).unwrap();
    assert_eq!(shared["project_materials"],json!([{
        "id":1,"project_id":project["id"],"label":"Смета ткани","url":"https://example.test/fabric",
        "local_url":"https://example.test/fabric?signature=synthetic#preview"
    }]));
    let mut result = output(segment);
    result["tasks"][0]["material_ids"] = json!([1,999]);
    store.groq_complete(analysis,&result).unwrap();
    let workspace = store.workspace(false,None).unwrap();
    let proposals = workspace["proposals"].as_array().unwrap();
    let task = proposals.iter().find(|item| item["kind"] == "create_task").unwrap();
    assert_eq!(task["source"]["material_links"],json!([{
        "id":1,"project_id":project["id"],"label":"Смета ткани",
        "url":"https://example.test/fabric?signature=synthetic#preview"
    }]));
}

#[test]
fn old_change_cards_cannot_capture_the_deadline_and_assignee_of_the_original_task() {
    let (dir, store, meeting, segment) = setup();
    let person = store.add_person("Давид").unwrap();
    let project = store.workspace_action(&json!({"op":"save_project","data":{
        "title":"Тенты","status":"active","stages":vtracker::workspace::default_stages()
    }})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting","id":meeting,"data":{
        "title":"Закупка","project_id":project["id"],"participants":[]
    }})).unwrap();
    let task = |title| store.workspace_action(&json!({"op":"save_task","data":{
        "title":title,"project_id":project["id"],"stage_id":"todo","due_date":"2026-11-30",
        "priority":"normal","blocked":false
    }})).unwrap();
    let original = task("Закупить ткань");
    let old_due = task("Перенести закупку ткани на 24-е число");
    let old_owner = task("Назначить Давида ответственным за закупку ткани");
    let connection = Connection::open(dir.path().join("db")).unwrap();
    connection.execute("UPDATE segments SET text='По закупке ткани срок 24 ноября, ответственный Давид' WHERE id=?1",
        [segment]).unwrap();
    for legacy in [&old_due,&old_owner] {
        let data = json!({"project_id":project["id"],"kind":"create_task","origin":"groq",
            "title":legacy["title"],"confirmed_task_id":legacy["id"],"source":{"meeting_id":meeting,"start_ms":0}});
        connection.execute("INSERT INTO proposals(data_json,is_demo,status) VALUES (?1,0,'accepted')",
            [data.to_string()]).unwrap();
    }
    let (run, context, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    assert_eq!(context["project_tasks"][0]["id"], original["id"]);
    assert_eq!(context["project_tasks"][0]["legacy_change_card"], false);
    assert_eq!(context["project_tasks"][1]["legacy_change_card"], true);
    assert_eq!(context["project_tasks"][2]["legacy_change_card"], true);
    let mut response = output(segment);
    response["decisions"] = json!([]);
    response["tasks"] = json!([
        {"kind":"change_due","title":old_due["title"],"task_id":old_due["id"],"description":"",
         "due_date":"2026-11-24","source_segment_ids":[segment]},
        {"kind":"change_assignee","title":old_owner["title"],"task_id":old_owner["id"],"description":"",
         "assignee_name":"Давид","source_segment_ids":[segment]}
    ]);
    store.groq_complete(run,&response).unwrap();
    let state = store.workspace(false,None).unwrap();
    let pending:Vec<_> = state["proposals"].as_array().unwrap().iter()
        .filter(|p| p["status"] == "pending").collect();
    assert_eq!(pending.len(),1);
    let bundle = pending[0];
    assert_eq!(bundle["kind"], "change_task");
    assert!(bundle["task_id"].is_null());
    assert_eq!(bundle["candidate_task_ids"],json!([original["id"]]));
    assert_eq!(bundle["proposed"]["assignee_id"],person);
    let mut edited = original.clone();
    edited["due_date"] = json!("2026-11-26");
    let edited = store.workspace_action(&json!({"op":"save_task","id":original["id"],"revision":original["revision"],"data":edited})).unwrap();
    let mut review = json!({"op":"review","id":bundle["id"],"existing_task_id":original["id"],
        "task_revision":edited["revision"],"data":bundle["proposed"]});
    assert!(store.workspace_action(&review).unwrap_err().to_string().contains("после анализа"));
    review["acknowledge_task_conflict"] = json!(true);
    let applied = store.workspace_action(&review).unwrap();
    assert_eq!(applied["task"]["id"],original["id"]);
    assert_eq!(applied["task"]["assignee_id"],person);
    assert_eq!(applied["task"]["due_date"],"2026-11-24");
    assert_eq!(store.workspace(false,None).unwrap()["tasks"].as_array().unwrap().len(),3);
}

#[test]
fn company_terms_are_saved_and_reused_in_meetings_without_sending_unrelated_terms() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("glossary.sqlite3");
    let store = Store::open(&path).unwrap();
    let connection = Connection::open(&path).unwrap();
    let (meeting, segment) = meeting_with_transcript(&store, &connection, "Декор", "Нужен сотик и термопруток");
    let term = |name, alias| json!({
        "op":"save_company_term",
        "data":{"term":name,"variants":[{"text":alias,"language":"ru"}],"section":"Материалы"}
    });
    let initial = store.workspace_action(&term("Панель", "карточка")).unwrap();
    let (first, _, _) = store.groq_prepare_projects(meeting, MODELS[0], true, false, &[], false).unwrap();
    store.groq_complete(first, &json!({
        "summary":"Уточнили материалы","tasks":[],"decisions":[],"open_questions":[],
        "observations":[
            {"kind":"unclear_term","text":"термопруток","source_segment_ids":[segment]},
            {"kind":"unclear_term","text":"выдуманный термин","source_segment_ids":[segment]}
        ]
    })).unwrap();
    let analysis = store.groq_analysis(meeting).unwrap();
    let findings = analysis["saved"]["result"]["findings"].as_array().unwrap();
    assert_eq!(findings.len(), 1);
    assert_eq!(findings[0]["text"], "термопруток");

    let entry = store.workspace_action(&term("Сотовый поликарбонат", "сотик")).unwrap();
    assert!(store.workspace_action(&term("Другое значение", "СОТИК")).is_err());
    let (second, input, cached) = store.groq_prepare_projects(meeting, MODELS[0], true, false, &[], false).unwrap();
    assert!(!cached);
    assert_ne!(first, second);
    let terms = input["company_terms"].as_array().unwrap();
    assert_eq!(terms.len(), 1);
    assert_eq!(terms[0]["term"], "Сотовый поликарбонат");
    assert_eq!(input["segments"][0]["text"], "Нужен сотик и термопруток");
    assert_eq!(store.workspace(false, None).unwrap()["company_terms"].as_array().unwrap().len(), 2);
    assert_eq!(store.workspace(true, None).unwrap()["company_terms"], json!([]));
    assert!(store.workspace_action(&json!({"op":"delete_company_term","id":entry["id"],"revision":0})).is_err());
    store.workspace_action(&json!({"op":"delete_company_term","id":initial["id"],"revision":initial["revision"]})).unwrap();
}

#[test]
fn changing_industry_refreshes_analysis_context_and_preserves_company_terms() {
    let (_dir, store, meeting, segment) = setup();
    let (first, _, _) = store.groq_prepare_projects(meeting, MODELS[0], true, false, &[], false).unwrap();
    store.groq_complete(first, &output(segment)).unwrap();
    let term = store.workspace_action(&json!({
        "op":"save_company_term",
        "data":{"term":"Сотовый поликарбонат","variants":[{"text":"сотик","language":"ru"}]}
    })).unwrap();
    assert!(store.workspace_action(&json!({"op":"settings","data":{"industry_template":"unknown"}})).is_err());
    store.workspace_action(&json!({"op":"settings","data":{"industry_template":"it"}})).unwrap();
    let state = store.workspace(false, None).unwrap();
    assert_eq!(state["settings"]["industry_template"], "it");
    assert_eq!(state["company_terms"][0]["id"], term["id"]);

    let (second, context, cached) = store.groq_prepare_projects(meeting, MODELS[0], true, false, &[], false).unwrap();
    assert_ne!(first, second);
    assert!(!cached);
    assert_eq!(context["industry_template"], "it");
}

#[test]
fn starter_glossary_combines_with_company_variants_and_switches_industry() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("glossary.sqlite3");
    let store = Store::open(&path).unwrap();
    let connection = Connection::open(&path).unwrap();
    let (meeting, _) = meeting_with_transcript(
        &store,
        &connection,
        "Релиз",
        "Завтра боевой выклад. Потом нужно выкатить на прод и проверить метрики.",
    );
    let select = |industry| {
        store.workspace_action(&json!({
            "op":"settings","data":{"industry_template":industry}
        })).unwrap();
    };
    select("it");
    let canonical = "Выкладка в рабочую среду";
    let company_variant = json!({"text":"боевой выклад","language":"ru"});
    store.workspace_action(&json!({
        "op":"save_company_term",
        "data":{"term":canonical,"variants":[company_variant]}
    })).unwrap();

    let state = store.workspace(false, None).unwrap();
    let includes = |terms: &serde_json::Value, term| {
        terms.as_array().unwrap().iter().any(|entry| entry["term"] == term)
    };
    assert!(includes(&state["industry_terms"], canonical));
    assert!(!includes(&state["industry_terms"], "Передача в пошив"));
    assert_eq!(state["company_terms"][0]["variants"], json!([company_variant]));
    let (_, snapshot, _) = store
        .groq_prepare_projects(meeting, MODELS[0], true, false, &[], false)
        .unwrap();
    let relevant = snapshot["company_terms"].as_array().unwrap();
    assert_eq!(relevant.len(), 1);
    assert_eq!(relevant[0]["term"], canonical);
    assert_eq!(relevant[0]["section"], "Релизы");
    let variants = relevant[0]["variants"].as_array().unwrap();
    assert!(variants.contains(&company_variant));
    assert!(variants.iter().any(|variant| variant["text"] == "выкатить на прод"));

    select("construction");
    let state = store.workspace(false, None).unwrap();
    assert!(includes(&state["industry_terms"], "Освидетельствование скрытых работ"));
    assert!(!includes(&state["industry_terms"], canonical));
    assert_eq!(state["company_terms"][0]["variants"], json!([company_variant]));
    let company_term = state["glossary_terms"].as_array().unwrap().iter()
        .find(|entry| entry["term"] == canonical).unwrap();
    assert_eq!(company_term["variants"], json!([company_variant]));
}
