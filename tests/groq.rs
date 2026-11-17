use rusqlite::{params, Connection};
use serde_json::{json, Value};
use vtracker::{
    groq::{GroqWorker, MODELS},
    Store,
};
fn setup() -> (tempfile::TempDir, Store, i64, i64) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let s = Store::open(&path).unwrap();
    let m = s.create_meeting("Planning").unwrap();
    let c = Connection::open(&path).unwrap();
    c.execute(
        "INSERT INTO processing_jobs(meeting_id,kind,status) VALUES (?1,'transcribe','completed')",
        [m],
    )
    .unwrap();
    let j = c.last_insert_rowid();
    c.execute("INSERT INTO model_runs(job_id,meeting_id,model_path,model_sha256,engine_path,engine_sha256,language,status,inputs_json) VALUES (?1,?2,'fixture',?3,'fixture',?3,'ru','completed','[]')",params![j,m,"0".repeat(64)]).unwrap();
    let run = c.last_insert_rowid();
    c.execute("INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,0,2000,'Prepare the report by Friday','[]')",[run]).unwrap();
    let seg = c.last_insert_rowid();
    (dir, s, m, seg)
}
fn output(seg: i64) -> Value {
    json!({"summary":"Agreed to prepare a report.","open_questions":["Who reviews it?"],"decisions":[{"text":"Prepare report","source_segment_ids":[seg]}],"tasks":[{"title":"Prepare report","description":"Draft report","assignee_name":null,"due_date":null,"source_segment_ids":[seg]}]})
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
fn reanalysis_preserves_pending_proposal_fields() {
    let (_dir, store, meeting, segment) = setup();
    let (first, _, _) = store.groq_prepare(meeting, MODELS[0], true).unwrap();
    let original = output(segment);
    store.groq_complete(first, &original).unwrap();
    let before = store.workspace(false, None).unwrap()["proposals"].clone();

    let (second, _, _) = store.groq_prepare(meeting, MODELS[1], true).unwrap();
    let mut updated = original;
    updated["tasks"][0]["description"] = json!("Different description");
    updated["tasks"][0]["due_date"] = json!("2026-11-30");
    store.groq_complete(second, &updated).unwrap();
    assert_eq!(store.workspace(false, None).unwrap()["proposals"], before);
}
