use chrono::{TimeZone, Utc};
use chrono_tz::Tz;
use serde_json::{json, Value};
use vtracker::{workspace::due_state, Store};
fn open() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db.sqlite3")).unwrap();
    (tmp, store)
}
fn task(store: &Store, title: &str, extra: Value) -> Value {
    let mut data = json!({"title":title,"description":"","project_id":null,"assignee_id":null,"author_id":null,"stage_id":"todo","priority":"normal","due_date":null,"due_time":null,"blocked":false,"blocked_reason":"","dependencies":[],"sources":[]});
    data.as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    store
        .workspace_action(&json!({"op":"save_task","data":data}))
        .unwrap()
}
#[test]
fn deadlines_use_local_end_of_day_dst_and_terminal_types() {
    let moscow: Tz = "Europe/Moscow".parse().unwrap();
    let now = Utc.with_ymd_and_hms(2026, 11, 1, 20, 59, 59).unwrap();
    assert_eq!(
        due_state(Some("2026-11-01"), None, true, now, moscow).unwrap(),
        "today"
    );
    assert_eq!(
        due_state(
            Some("2026-11-01"),
            None,
            true,
            now + chrono::Duration::seconds(1),
            moscow
        )
        .unwrap(),
        "overdue"
    );
    assert_eq!(
        due_state(Some("2026-11-01"), Some("23:00"), true, now, moscow).unwrap(),
        "overdue"
    );
    assert_eq!(
        due_state(Some("2000-01-01"), None, false, now, moscow).unwrap(),
        "closed"
    );
    assert_eq!(due_state(None, None, true, now, moscow).unwrap(), "none");
    let ny: Tz = "America/New_York".parse().unwrap();
    assert_eq!(
        due_state(
            Some("2026-03-08"),
            None,
            true,
            Utc.with_ymd_and_hms(2026, 3, 9, 3, 59, 59).unwrap(),
            ny
        )
        .unwrap(),
        "today"
    );
    assert_eq!(
        due_state(
            Some("2026-03-08"),
            None,
            true,
            Utc.with_ymd_and_hms(2026, 3, 9, 4, 0, 0).unwrap(),
            ny
        )
        .unwrap(),
        "overdue"
    );
    assert!(due_state(Some("2026-03-08"), Some("02:30"), true, now, ny).is_err());
}
#[test]
fn task_updates_are_shared_versioned_and_do_not_complete_projects() {
    let (_tmp, store) = open();
    let project=store.workspace_action(&json!({"op":"save_project","data":{"title":"P","status":"paused","end_date":"2020-01-01","stages":vtracker::workspace::default_stages()}})).unwrap();
    let t = task(
        &store,
        "T",
        json!({"project_id":project["id"],"due_date":"2020-01-01"}),
    );
    let now = Utc.with_ymd_and_hms(2026, 11, 1, 12, 0, 0).unwrap();
    let w = store.workspace(false, Some(now)).unwrap();
    assert_eq!(w["tasks"][0]["overdue"], true);
    assert_eq!(w["projects"][0]["overdue"], true);
    let mut data = t.clone();
    data["stage_id"] = json!("done");
    store
        .workspace_action(
            &json!({"op":"save_task","id":t["id"],"revision":t["revision"],"data":data}),
        )
        .unwrap();
    let w = store.workspace(false, Some(now)).unwrap();
    assert_eq!(w["tasks"][0]["active"], false);
    assert_eq!(w["projects"][0]["status"], "paused");
    assert_eq!(w["projects"][0]["task_counts"]["overdue"], 0);
    assert_eq!(w["projects"][0]["task_counts"]["done"], 1);
    assert!(store
        .workspace_action(&json!({"op":"save_task","id":t["id"],"revision":t["revision"],"data":t}))
        .is_err());
}
#[test]
fn occupied_stage_requires_explicit_migration_and_rolls_back_on_error() {
    let (_tmp, store) = open();
    let p=store.workspace_action(&json!({"op":"save_project","data":{"title":"P","status":"active","stages":vtracker::workspace::default_stages()}})).unwrap();
    let t = task(&store, "T", json!({"project_id":p["id"]}));
    let mut data = p.clone();
    data["stages"]
        .as_array_mut()
        .unwrap()
        .retain(|s| s["id"] != "todo");
    assert!(store
        .workspace_action(
            &json!({"op":"save_project","id":p["id"],"revision":p["revision"],"data":data})
        )
        .is_err());
    assert_eq!(
        store.workspace(false, None).unwrap()["projects"][0]["revision"],
        1
    );
    store.workspace_action(&json!({"op":"save_project","id":p["id"],"revision":p["revision"],"data":data,"migrate_stages":{"todo":"doing"}})).unwrap();
    assert_eq!(
        store.workspace(false, None).unwrap()["tasks"][0]["stage_id"],
        "doing"
    );
    assert_eq!(
        store.workspace(false, None).unwrap()["tasks"][0]["id"],
        t["id"]
    );
}
#[test]
fn batch_undo_is_atomic_and_refuses_to_clobber_later_edits() {
    let (_tmp, store) = open();
    let a = task(&store, "A", json!({}));
    let b = task(&store, "B", json!({}));
    let items: Vec<_> = [&a, &b]
        .into_iter()
        .map(|t| {
            let mut d = t.clone();
            d["priority"] = json!("high");
            json!({"id":t["id"],"revision":t["revision"],"data":d})
        })
        .collect();
    let result = store
        .workspace_action(&json!({"op":"batch_tasks","items":items}))
        .unwrap();
    assert_eq!(
        store.workspace(false, None).unwrap()["tasks"][0]["priority"],
        "high"
    );
    store
        .workspace_action(&json!({"op":"undo_batch","batch_id":result["batch_id"]}))
        .unwrap();
    assert_eq!(
        store.workspace(false, None).unwrap()["tasks"][0]["priority"],
        "normal"
    );
    let w = store.workspace(false, None).unwrap();
    let items: Vec<_> = w["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| {
            let mut d = t.clone();
            d["priority"] = json!("critical");
            json!({"id":t["id"],"revision":t["revision"],"data":d})
        })
        .collect();
    let result = store
        .workspace_action(&json!({"op":"batch_tasks","items":items}))
        .unwrap();
    let t = store.workspace(false, None).unwrap()["tasks"][0].clone();
    store
        .workspace_action(&json!({"op":"save_task","id":t["id"],"revision":t["revision"],"data":t}))
        .unwrap();
    assert!(store
        .workspace_action(&json!({"op":"undo_batch","batch_id":result["batch_id"]}))
        .is_err());
    assert_eq!(
        store.workspace(false, None).unwrap()["tasks"][1]["priority"],
        "critical"
    );
}
#[test]
fn demo_is_isolated_persistent_and_review_does_not_count_before_confirmation() {
    let (tmp, store) = open();
    store.workspace_action(&json!({"op":"seed_demo"})).unwrap();
    let demo = store.workspace(true, None).unwrap();
    assert_eq!(demo["projects"].as_array().unwrap().len(), 3);
    assert_eq!(demo["tasks"].as_array().unwrap().len(), 15);
    assert_eq!(demo["meetings"].as_array().unwrap().len(), 3);
    assert!(store.workspace(false, None).unwrap()["tasks"]
        .as_array()
        .unwrap()
        .is_empty());
    let proposal = demo["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "create_task")
        .unwrap();
    let data = json!({"title":"Approved","project_id":proposal["project_id"],"stage_id":"todo","priority":"normal","blocked":false,"assignee_id":null,"due_date":null,"sources":[],"dependencies":[]});
    store
        .workspace_action(&json!({"op":"review","demo":true,"id":proposal["id"],"data":data}))
        .unwrap();
    assert_eq!(
        store.workspace(true, None).unwrap()["tasks"]
            .as_array()
            .unwrap()
            .len(),
        16
    );
    assert!(store
        .workspace_action(&json!({"op":"review","demo":true,"id":proposal["id"],"data":data}))
        .is_err());
    drop(store);
    let store = Store::open(&tmp.path().join("db.sqlite3")).unwrap();
    store.workspace_action(&json!({"op":"seed_demo"})).unwrap();
    assert_eq!(
        store.workspace(true, None).unwrap()["tasks"]
            .as_array()
            .unwrap()
            .len(),
        16
    );
    assert!(store
        .enqueue(demo["meetings"][0]["id"].as_i64().unwrap())
        .is_err());
}
#[test]
fn task_dependencies_cannot_form_cycles() {
    let (_tmp, store) = open();
    let a = task(&store, "A", json!({}));
    let b = task(&store, "B", json!({"dependencies":[a["id"]]}));
    let mut data = a.clone();
    data["dependencies"] = json!([b["id"]]);
    assert!(store
        .workspace_action(
            &json!({"op":"save_task","id":a["id"],"revision":a["revision"],"data":data})
        )
        .is_err());
}

#[test]
fn date_only_deadlines_handle_midnight_clock_changes() {
    let havana: Tz = "America/Havana".parse().unwrap();
    assert_eq!(
        due_state(
            Some("2026-10-31"),
            None,
            true,
            Utc.with_ymd_and_hms(2026, 11, 1, 4, 30, 0).unwrap(),
            havana
        )
        .unwrap(),
        "overdue"
    );
    assert_ne!(
        due_state(
            Some("2026-03-07"),
            None,
            true,
            Utc.with_ymd_and_hms(2026, 3, 8, 4, 59, 59).unwrap(),
            havana
        )
        .unwrap(),
        "overdue"
    );
    assert_eq!(
        due_state(
            Some("2026-03-07"),
            None,
            true,
            Utc.with_ymd_and_hms(2026, 3, 8, 5, 0, 0).unwrap(),
            havana
        )
        .unwrap(),
        "overdue"
    );
}

#[test]
fn proposals_update_only_after_review_and_duplicates_link_without_extra_tasks() {
    let (_tmp, store) = open();
    let now = Utc.with_ymd_and_hms(2026, 11, 2, 9, 0, 0).unwrap();
    store.seed_demo_at(now).unwrap();
    let w = store.workspace(true, Some(now)).unwrap();
    assert!(w["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["due_state"] == "today"));
    assert!(w["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["active"] == true && t["due_state"] == "upcoming"));
    let change = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "change_due")
        .unwrap();
    let target = w["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == change["task_id"])
        .unwrap();
    let old_stage = target["stage_id"].clone();
    assert!(store.workspace_action(&json!({"op":"review","demo":true,"id":change["id"],"task_revision":0,"data":{"due_date":"2026-12-01"}})).is_err());
    store.workspace_action(&json!({"op":"review","demo":true,"id":change["id"],"task_revision":target["revision"],"data":{"due_date":"2026-12-01","due_time":null}})).unwrap();
    let after = store.workspace(true, Some(now)).unwrap();
    let updated = after["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == target["id"])
        .unwrap();
    assert_eq!(updated["due_date"], "2026-12-01");
    assert_eq!(updated["stage_id"], old_stage);
    let create = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "create_task")
        .unwrap();
    store.workspace_action(&json!({"op":"review","demo":true,"id":create["id"],"existing_task_id":target["id"],"data":{}})).unwrap();
    assert_eq!(
        store.workspace(true, None).unwrap()["tasks"]
            .as_array()
            .unwrap()
            .len(),
        15
    );
    let decision = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["kind"] == "decision")
        .unwrap();
    store.workspace_action(&json!({"op":"review","demo":true,"id":decision["id"],"data":{"title":"Confirmed decision","project_id":decision["project_id"]}})).unwrap();
    assert_eq!(
        store.workspace(true, None).unwrap()["decisions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn project_names_remain_unique_after_normalizing_case_and_spaces() {
    let (_tmp, store) = open();
    let create = |title: &str| {
        store.workspace_action(&json!({
            "op": "save_project", "data": {"title": title, "status": "active"}
        }))
    };
    let project = create("Лён и ткани").unwrap();
    assert!(create("  ЛЕН   и ткани  ").unwrap_err().to_string().contains("уже существует"));
    let other = create("Другой проект").unwrap();
    let rename = store.workspace_action(&json!({
        "op": "save_project", "id": other["id"], "revision": other["revision"],
        "data": {"title": "лён и ткани", "status": "active"}
    }));
    assert!(rename.is_err());
    store.workspace_action(&json!({
        "op": "archive_project", "id": project["id"], "revision": project["revision"], "archived": true
    })).unwrap();
    assert!(create("Лён и ткани").unwrap_err().to_string().contains("уже есть в архиве"));
    let workspace = store.workspace(false, None).unwrap();
    assert_eq!(workspace["projects"].as_array().unwrap().len(), 2);
}

#[test]
fn project_archive_preserves_tasks_and_project_details() {
    let (_tmp, store) = open();
    let project = store
        .workspace_action(&json!({
            "op":"save_project", "data":{
                "title":"Проект", "status":"active", "materials":"Лён",
                "start_date":"2026-11-01", "end_date":"2026-11-30"
            }
        }))
        .unwrap();
    let item = task(
        &store,
        "Закупить ткань",
        json!({"project_id":project["id"]}),
    );
    let archive = |project: &Value, archived| {
        store.workspace_action(&json!({
        "op":"archive_project","id":project["id"],"revision":project["revision"],"archived":archived
    }))
    };
    let archived = archive(&project, true).unwrap();
    assert_eq!(archived["archived"], true);
    assert!(archive(&project, false).is_err());
    let restored = archive(&archived, false).unwrap();
    assert_eq!(restored["archived"], false);
    assert_eq!(restored["materials"], "Лён");
    assert_eq!(restored["end_date"], "2026-11-30");
    let workspace = store.workspace(false, None).unwrap();
    let saved_task = workspace["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == item["id"])
        .unwrap();
    assert_eq!(saved_task["project_id"], project["id"]);
    assert_eq!(saved_task["revision"], item["revision"]);
}

#[test]
fn participant_profile_survives_upgrade_and_reopen() {
    let (tmp, store) = open();
    let path = tmp.path().join("db.sqlite3");
    let id = store.add_person("Лена").unwrap();
    drop(store);

    let old = rusqlite::Connection::open(&path).unwrap();
    old.execute_batch("DROP TABLE meeting_terminology; DROP INDEX meeting_analyses_term_findings; DROP TABLE term_reviews; DROP TABLE company_terms; DROP TABLE live_voice_hints; DROP TABLE task_notifications; DROP TABLE task_links; DROP TABLE decision_tasks; DROP TABLE decision_context; DROP TABLE ai_extraction_cache; DROP TABLE ai_usage; DROP TABLE person_profiles; DROP TABLE speech_blocks; DROP TABLE speaker_blocks; ALTER TABLE live_chunks DROP COLUMN last_sequence; ALTER TABLE live_sessions DROP COLUMN speaker_turns_json; ALTER TABLE live_sessions DROP COLUMN speaker_profiles_json; ALTER TABLE processing_jobs DROP COLUMN stage; ALTER TABLE processing_jobs DROP COLUMN started_at; ALTER TABLE processing_jobs DROP COLUMN finished_at; PRAGMA user_version=17;")
        .unwrap();
    drop(old);

    let store = Store::open(&path).unwrap();
    assert_eq!(store.people().unwrap()[0]["name"], "Лена");
    assert!(store.people().unwrap()[0]["email"].is_null());
    store.workspace_action(&json!({
        "op":"save_person", "id":id,
        "data":{"name":"Елена","last_name":"Иванова","patronymic":"Сергеевна","role":"Дизайнер","organization":"Студия",
                "email":"elena@example.test","phone":"+7 900 000 00 00","notes":"Работает над макетом"}
    })).unwrap();
    drop(store);

    let store = Store::open(&path).unwrap();
    let people = store.people().unwrap();
    assert_eq!(people[0]["id"], id);
    assert_eq!(people[0]["name"], "Елена");
    assert_eq!(people[0]["last_name"], "Иванова");
    assert_eq!(people[0]["patronymic"], "Сергеевна");
    assert_eq!(people[0]["role"], "Дизайнер");
    assert_eq!(people[0]["organization"], "Студия");
    assert_eq!(people[0]["email"], "elena@example.test");
    assert_eq!(people[0]["phone"], "+7 900 000 00 00");
    assert_eq!(people[0]["notes"], "Работает над макетом");
}

#[test]
fn work_periods_are_independent_of_task_statuses_and_survive_legacy_updates() {
    let (_tmp, store) = open();
    let original = store.workspace_action(&json!({
        "op": "save_project", "data": {"title": "Оформление", "status": "planned"}
    })).unwrap();
    let edit = |revision: &Value, data: Value| {
        store.workspace_action(&json!({
            "op": "save_project", "id": original["id"], "revision": revision, "data": data
        }))
    };
    let saved = edit(&original["revision"], json!({
        "title": "Оформление", "status": "planned",
        "start_date": "2026-12-01", "end_date": "2026-12-19",
        "work_periods": [
            {"id": "prep", "title": " Подготовка ", "end_date": "2026-12-16"},
            {"id": "setup", "title": "Монтаж", "start_date": "2026-12-17", "end_date": "2026-12-18"},
            {"id": "close", "title": "Демонтаж"}
        ]
    })).unwrap();
    assert_eq!(saved["stages"], original["stages"]);
    assert_eq!(saved["work_periods"][0], json!({
        "id":"prep", "title":"Подготовка", "start_date":null, "end_date":"2026-12-16"
    }));
    assert_eq!(saved["work_periods"][2]["end_date"], Value::Null);
    let legacy = edit(&saved["revision"], json!({"title": "Оформление", "status": "active"})).unwrap();
    assert_eq!(legacy["work_periods"], saved["work_periods"]);

    for invalid in [
        json!([{"id":"x", "title":"Монтаж","start_date":"2026-12-18","end_date":"2026-12-17"}]),
        json!([{"id":"x", "title":"Монтаж","start_date":"2026-02-30"}]),
        json!([{"id":"x", "title":"   "}]),
        json!([{"id":"x","title":"Монтаж"},{"id":"x","title":"Демонтаж"}]),
        json!({"title":"Монтаж"}),
    ] {
        assert!(edit(&legacy["revision"], json!({
            "title": "Оформление", "status": "active", "work_periods": invalid
        })).is_err());
    }
    let workspace = store.workspace(false, None).unwrap();
    assert_eq!(workspace["projects"][0]["work_periods"], saved["work_periods"]);
    let cleared = edit(&legacy["revision"], json!({
        "title":"Оформление", "status":"active", "work_periods":[]
    })).unwrap();
    assert_eq!(cleared["work_periods"], json!([]));
}

#[test]
fn work_period_catalog_has_industry_defaults_and_editable_company_entries() {
    let (tmp, store) = open();
    let snapshot = store.workspace(false, None).unwrap();
    let entries = snapshot["work_period_catalog"].as_array().unwrap();
    for industry in snapshot["industry_catalog"].as_array().unwrap() {
        assert!(entries.iter().any(|entry| entry["industry_id"] == industry["id"]));
    }
    assert!(entries.iter().any(|entry| {
        entry["industry_id"] == "events" && entry["title"] == "Монтаж" && entry["built_in"] == true
    }));
    for (slug, phase) in [
        ("venue", "Бриф и планирование"),
        ("invitations", "Программа и работа с гостями"),
        ("decor-design", "Площадка, декор и техническая подготовка"),
        ("setup", "Монтаж и готовность к открытию"),
        ("event", "День мероприятия"),
        ("settlement", "Демонтаж и закрытие"),
    ] {
        let id = format!("builtin:events:{slug}");
        assert!(entries.iter().any(|entry| entry["id"] == id && entry["phase"] == phase));
    }
    let store_template = |workspace: &Store, demo, data: Value| {
        workspace.workspace_action(&json!({
            "op": "save_work_period_template", "demo": demo, "data": data
        }))
    };
    let created = store_template(&store, false, json!({
        "title": "  Примерка декораций  ", "industry_id": "events"
    })).unwrap();
    assert_eq!(created["title"], "Примерка декораций");
    assert_eq!(created["built_in"], false);
    assert!(store_template(&store, false, json!({
        "title": "ПРИМЕРКА   декораций", "industry_id": "events"
    })).is_err());
    assert!(store_template(&store, false, json!({
        "title": "Подбор и бронирование площадки", "industry_id": "events"
    })).is_err());
    assert!(store_template(&store, false, json!({
        "id": "builtin:events:setup", "title": "Переименование", "industry_id": "events"
    })).is_err());
    assert!(store_template(&store, false, json!({
        "title": "Черновик", "industry_id": "unknown"
    })).is_err());

    let renamed = store_template(&store, false, json!({
        "id": created["id"], "title": "Примерка на площадке", "industry_id": "universal"
    })).unwrap();
    assert_eq!(renamed["id"], created["id"]);
    assert!(store_template(&store, true, json!({
        "id": created["id"], "title": "Демо", "industry_id": "universal"
    })).is_err());

    let project = store.workspace_action(&json!({
        "op": "save_project", "data": {
            "title": "Декор", "status": "planned", "work_periods": [{"id": "local", "title": "Монтаж"}]
        }
    })).unwrap();
    let project = store.workspace_action(&json!({
        "op": "save_project", "id": project["id"], "revision": project["revision"], "data": {
            "title": "Декор", "status": "planned", "work_periods": [{"id": "local", "title": "Монтаж сцены"}]
        }
    })).unwrap();
    assert_eq!(project["work_periods"][0]["title"], "Монтаж сцены");
    drop(store);

    let reopened = Store::open(&tmp.path().join("db.sqlite3")).unwrap();
    let current = reopened.workspace(false, None).unwrap();
    assert!(current["work_period_catalog"].as_array().unwrap().contains(&renamed));
    assert!(current["work_period_catalog"].as_array().unwrap().iter().any(|entry| entry["title"] == "Монтаж"));
    assert_eq!(current["projects"][0]["work_periods"][0]["title"], "Монтаж сцены");
    assert!(!reopened.workspace(true, None).unwrap()["work_period_catalog"].as_array().unwrap().contains(&renamed));
}

#[test]
fn event_work_period_lists_are_independent_and_preserve_projects() {
    let (tmp, store) = open();
    let project = store.workspace_action(&json!({
        "op": "save_project", "data": {
            "title": "Оформление зала", "status": "planned",
            "work_periods": [{"id":"local","title":"Концепция"}]
        }
    })).unwrap();
    let snapshot = store.workspace(false, None).unwrap();
    let lists = &snapshot["event_work_period_lists"];
    let decor = lists["decor"].as_array().unwrap();
    let base: Vec<_> = decor.iter().map(|entry| json!({
        "id": entry["id"], "title": entry["title"]
    })).collect();
    let changed = json!([
        {"id": base[1]["id"], "title": "Концепция оформления"},
        base[0],
        {"id": "custom:00112233445566778899aabbccddeeff", "title": "Примерка на площадке"}
    ]);
    let save = |base: &[Value], items: Value, kind: &str| store.workspace_action(&json!({
        "op":"save_work_period_list", "data":{
            "industry_id":"events", "project_type":kind, "base":base, "items":items
        }
    }));
    assert!(save(&base, changed.clone(), "decor").is_ok());
    assert!(save(&base, changed.clone(), "decor").is_ok());
    assert!(save(&base, json!([]), "decor").is_err());
    assert!(save(&base, changed.clone(), "organization").is_err());

    let reopened = Store::open(&tmp.path().join("db.sqlite3")).unwrap();
    let after = reopened.workspace(false, None).unwrap();
    let updated = after["event_work_period_lists"]["decor"].as_array().unwrap();
    assert_eq!(updated.len(), 3);
    for (row, item) in updated.iter().zip(changed.as_array().unwrap()) {
        assert_eq!(row["id"], item["id"]);
        assert_eq!(row["title"], item["title"]);
    }
    assert_eq!(after["event_work_period_lists"]["organization"], lists["organization"]);
    assert_eq!(after["projects"][0]["work_periods"], project["work_periods"]);
    let demo = reopened.workspace(true, None).unwrap();
    assert_eq!(demo["event_work_period_lists"]["decor"], lists["decor"]);
}
