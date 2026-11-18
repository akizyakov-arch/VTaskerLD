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
