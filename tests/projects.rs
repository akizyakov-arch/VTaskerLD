use serde_json::{json, Value};
use vtracker::Store;

fn project(store: &Store) -> Value {
    store.workspace_action(&json!({"op":"save_project","data":{"title":"Project","status":"active","description":"Legacy description","goal":"  Deliver a working application  ","next_milestone":"Review prototype","next_milestone_date":"2026-11-05","blocker":"Waiting for criteria"}})).unwrap()
}

#[test]
fn project_context_survives_reopen_and_legacy_client_updates() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let store = Store::open(&path).unwrap();
    let p = project(&store);
    assert_eq!(p["goal"], "Deliver a working application");
    drop(store);
    let store = Store::open(&path).unwrap();
    let current = store.workspace(false, None).unwrap()["projects"][0].clone();
    assert_eq!(current["blocker"], "Waiting for criteria");
    let mut legacy = current.clone();
    for key in ["goal", "next_milestone", "next_milestone_date", "blocker"] {
        legacy.as_object_mut().unwrap().remove(key);
    }
    legacy["title"] = json!("Renamed by older client");
    let saved = store
        .workspace_action(
            &json!({"op":"save_project","id":p["id"],"revision":current["revision"],"data":legacy}),
        )
        .unwrap();
    assert_eq!(saved["goal"], current["goal"]);
    assert_eq!(saved["next_milestone_date"], "2026-11-05");
    assert_eq!(saved["blocker"], current["blocker"]);
    let history = store
        .workspace_action(&json!({"op":"history","entity":"projects","id":p["id"]}))
        .unwrap();
    assert_eq!(history.as_array().unwrap().len(), 2);
    assert!(store.workspace(false, None).unwrap()["tasks"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn invalid_project_context_rolls_back_without_touching_revision() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(&dir.path().join("db")).unwrap();
    let p = project(&store);
    for (key, value) in [
        ("goal", json!(42)),
        ("next_milestone", json!("x".repeat(501))),
        ("blocker", json!(false)),
        ("goal", json!("x".repeat(4001))),
        ("next_milestone_date", json!("2026-02-30")),
        ("next_milestone_date", json!(42)),
    ] {
        let mut data = p.clone();
        data[key] = value;
        assert!(
            store
                .workspace_action(
                    &json!({"op":"save_project","id":p["id"],"revision":p["revision"],"data":data})
                )
                .is_err(),
            "{key}"
        );
    }
    let mut data = p.clone();
    data["next_milestone"] = json!("");
    assert!(store
        .workspace_action(
            &json!({"op":"save_project","id":p["id"],"revision":p["revision"],"data":data})
        )
        .is_err());
    let unchanged = store.workspace(false, None).unwrap()["projects"][0].clone();
    assert_eq!(unchanged["revision"], 1);
    assert_eq!(unchanged["goal"], p["goal"]);
}

#[test]
fn context_can_be_cleared_and_stale_changes_cannot_replace_it() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(&dir.path().join("db")).unwrap();
    let p = project(&store);
    let mut data = p.clone();
    for key in ["goal", "next_milestone", "blocker", "next_milestone_date"] {
        data[key] = Value::Null;
    }
    let cleared = store
        .workspace_action(
            &json!({"op":"save_project","id":p["id"],"revision":p["revision"],"data":data}),
        )
        .unwrap();
    assert_eq!(cleared["goal"], "");
    assert_eq!(cleared["blocker"], "");
    assert!(cleared["next_milestone_date"].is_null());
    assert!(store
        .workspace_action(
            &json!({"op":"save_project","id":p["id"],"revision":p["revision"],"data":p})
        )
        .is_err());
    assert_eq!(
        store.workspace(false, None).unwrap()["projects"][0]["revision"],
        2
    );
}
