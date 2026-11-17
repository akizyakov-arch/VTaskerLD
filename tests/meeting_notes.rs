use serde_json::json;
use vtracker::Store;

#[test]
fn notes_are_durable_audited_and_do_not_create_tasks_or_touch_transcripts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db.sqlite3");
    let store = Store::open(&path).unwrap();
    let meeting = store.create_meeting("Meeting results").unwrap();
    let before = store.export(meeting).unwrap();
    let result = store.workspace_action(&json!({"op":"save_meeting_notes","meeting_id":meeting,"revision":0,"summary":"  Agreed next step  ","open_questions":"Who reviews?","author_name":"forged","author_id":999})).unwrap();
    assert_eq!(result["revision"], 1);
    assert_eq!(result["summary"], "Agreed next step");
    assert_eq!(result["author_name"], "Локальный пользователь");
    assert!(result["author_id"].is_null());
    assert_eq!(
        store.export(meeting).unwrap()["transcript"],
        before["transcript"]
    );
    assert!(store.workspace(false, None).unwrap()["tasks"]
        .as_array()
        .unwrap()
        .is_empty());
    drop(store);
    let reopened = Store::open(&path).unwrap();
    assert_eq!(
        reopened.meeting_notes(meeting).unwrap()["summary"],
        "Agreed next step"
    );
    let h = reopened
        .workspace_action(&json!({"op":"meeting_notes_history","meeting_id":meeting}))
        .unwrap();
    assert_eq!(h.as_array().unwrap().len(), 1);
    assert_eq!(h[0]["before"]["revision"], 0);
    assert_eq!(h[0]["after"]["revision"], 1);
    assert!(h[0]["created_at"].as_str().unwrap().ends_with('Z'));
}

#[test]
fn stale_edits_are_rejected_and_unchanged_retries_do_not_duplicate_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db.sqlite3");
    let a = Store::open(&path).unwrap();
    let m = a.create_meeting("Concurrent edits").unwrap();
    let b = Store::open(&path).unwrap();
    let payload = json!({"op":"save_meeting_notes","meeting_id":m,"revision":0,"summary":"first","open_questions":""});
    a.workspace_action(&payload).unwrap();
    let mut stale = payload.clone();
    stale["summary"] = json!("stale");
    assert!(b.workspace_action(&stale).is_err());
    b.workspace_action(&json!({"op":"save_meeting_notes","meeting_id":m,"revision":1,"summary":"first","open_questions":""})).unwrap();
    assert_eq!(a.meeting_notes(m).unwrap()["revision"], 1);
    let history = a
        .workspace_action(&json!({"op":"meeting_notes_history","meeting_id":m}))
        .unwrap();
    assert_eq!(history.as_array().unwrap().len(), 1);
}

#[test]
fn scope_limits_and_author_are_enforced_before_any_change() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(&dir.path().join("db")).unwrap();
    let m = store.create_meeting("Real meeting").unwrap();
    let author = store.add_person("User 1").unwrap();
    store
        .workspace_action(&json!({"op":"settings","data":{"me_id":author}}))
        .unwrap();
    let base = json!({"op":"save_meeting_notes","meeting_id":m,"revision":0,"summary":"notes","open_questions":""});
    let mut invalid = base.clone();
    invalid["demo"] = json!(true);
    assert!(store.workspace_action(&invalid).is_err());
    invalid = base.clone();
    invalid["summary"] = json!("x".repeat(20001));
    assert!(store.workspace_action(&invalid).is_err());
    invalid = base.clone();
    invalid["summary"] = json!(8);
    assert!(store.workspace_action(&invalid).is_err());
    invalid = base.clone();
    invalid["revision"] = json!(-1);
    assert!(store.workspace_action(&invalid).is_err());
    assert_eq!(store.meeting_notes(m).unwrap()["revision"], 0);
    let saved = store.workspace_action(&base).unwrap();
    assert_eq!(saved["author_id"], author);
    assert_eq!(saved["author_name"], "User 1");
    assert!(store
        .workspace_action(&json!({"op":"meeting_notes_history","meeting_id":m,"demo":true}))
        .is_err());
}

#[test]
fn clearing_notes_keeps_previous_version_in_history() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(&dir.path().join("db")).unwrap();
    let m = store.create_meeting("Clear notes").unwrap();
    store.workspace_action(&json!({"op":"save_meeting_notes","meeting_id":m,"revision":0,"summary":"retain in history","open_questions":"question"})).unwrap();
    store.workspace_action(&json!({"op":"save_meeting_notes","meeting_id":m,"revision":1,"summary":"","open_questions":""})).unwrap();
    let h = store
        .workspace_action(&json!({"op":"meeting_notes_history","meeting_id":m}))
        .unwrap();
    assert_eq!(h.as_array().unwrap().len(), 2);
    assert_eq!(h[0]["before"]["summary"], "retain in history");
    assert_eq!(h[0]["after"]["summary"], "");
}

#[test]
fn v13_upgrade_keeps_existing_meetings() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let store = Store::open(&path).unwrap();
    let m = store.create_meeting("Existing meeting").unwrap();
    drop(store);
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch(
        "DROP TABLE meeting_analyses; DROP TABLE meeting_notes; DROP TABLE person_profiles; ALTER TABLE meetings DROP COLUMN scheduled_at; DROP TABLE speech_blocks; DROP TABLE speaker_blocks; ALTER TABLE live_chunks DROP COLUMN last_sequence; ALTER TABLE live_sessions DROP COLUMN speaker_turns_json; ALTER TABLE live_sessions DROP COLUMN speaker_profiles_json; ALTER TABLE processing_jobs DROP COLUMN stage; ALTER TABLE processing_jobs DROP COLUMN started_at; ALTER TABLE processing_jobs DROP COLUMN finished_at; PRAGMA user_version=13;",
    )
    .unwrap();
    drop(c);
    let store = Store::open(&path).unwrap();
    assert_eq!(
        store.export(m).unwrap()["meeting"]["title"],
        "Existing meeting"
    );
    assert_eq!(store.meeting_notes(m).unwrap()["revision"], 0);
}
