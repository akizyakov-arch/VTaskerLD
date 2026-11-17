#![cfg(unix)]
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use vtracker::{voice_capture::VoiceCapture, Store};
fn setup() -> (tempfile::TempDir, Store, i64, VoiceCapture) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let person = store.add_person("Test participant").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/voice_capture.py");
    let capture = VoiceCapture::new(tmp.path().join("drafts"), helper).unwrap();
    (tmp, store, person, capture)
}
fn wait(c: &mut VoiceCapture, states: &[&str]) -> Value {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        c.poll().unwrap();
        let s = c.status();
        if states.contains(&s["draft"]["state"].as_str().unwrap_or("")) {
            return s["draft"].clone();
        }
        assert!(Instant::now() < deadline, "{s}");
        std::thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn enrollment_requires_consent_preview_and_confirmation_without_creating_meeting() {
    let (tmp, store, p, mut c) = setup();
    assert!(c.start(&store, p, "", false).is_err());
    assert!(c.status()["draft"].is_null());
    let state = c.start(&store, p, "", true).unwrap();
    let id = state["draft"]["id"].as_str().unwrap();
    assert!(c.busy());
    assert!(c.audio(id).is_err());
    assert!(c
        .accept(&store, id, p, &tmp.path().join("voice"), true, true)
        .is_err());
    wait(&mut c, &["recording"]);
    c.stop(id, p).unwrap();
    let ready = wait(&mut c, &["ready"]);
    assert_eq!(ready["quality"]["duration_seconds"], 8.0);
    assert!(!c.busy());
    assert!(c.audio(id).unwrap().is_file());
    assert!(store.meetings().unwrap().as_array().unwrap().is_empty());
    assert!(store.voice_snapshot().unwrap()["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(c
        .accept(&store, id, p, &tmp.path().join("voice"), true, false)
        .is_err());
    let job = c
        .accept(&store, id, p, &tmp.path().join("voice"), true, true)
        .unwrap();
    assert_eq!(
        c.accept(&store, id, p, &tmp.path().join("voice"), true, true)
            .unwrap(),
        job
    );
    assert!(c.audio(id).is_err());
    let voice = store.voice_snapshot().unwrap();
    assert_eq!(voice["jobs"].as_array().unwrap().len(), 1);
    assert!(voice["profiles"].as_array().unwrap().is_empty());
    assert_eq!(
        std::fs::read_dir(tmp.path().join("drafts"))
            .unwrap()
            .count(),
        1
    );
}
#[test]
fn cancellation_and_different_owner_cannot_enroll_a_draft() {
    let (tmp, store, p, mut c) = setup();
    let other = store.add_person("Other participant").unwrap();
    let s = c.start(&store, p, "", true).unwrap();
    let id = s["draft"]["id"].as_str().unwrap();
    wait(&mut c, &["recording"]);
    assert!(c.start(&store, other, "", true).is_err());
    assert!(c.stop(id, other).is_err());
    assert!(c.cancel(id, other).is_err());
    assert!(c
        .accept(&store, id, other, &tmp.path().join("voice"), true, true)
        .is_err());
    c.cancel(id, p).unwrap();
    assert!(!c.busy());
    assert!(c.status()["draft"].is_null());
    assert_eq!(
        std::fs::read_dir(tmp.path().join("drafts"))
            .unwrap()
            .count(),
        1
    );
    assert!(store.voice_snapshot().unwrap()["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn silent_sample_is_previewable_but_never_accepted() {
    let (tmp, store, p, mut c) = setup();
    let s = c.start(&store, p, "quiet", true).unwrap();
    let id = s["draft"]["id"].as_str().unwrap();
    wait(&mut c, &["recording"]);
    c.stop(id, p).unwrap();
    let rejected = wait(&mut c, &["rejected"]);
    assert!(rejected["error"].as_str().unwrap().contains("тихий"));
    assert!(c.audio(id).is_ok());
    assert!(c
        .accept(&store, id, p, &tmp.path().join("voice"), true, true)
        .is_err());
    c.cancel(id, p).unwrap();
}
#[test]
fn disconnected_microphone_has_no_silent_fallback_or_profile() {
    let (tmp, store, p, mut c) = setup();
    c.start(&store, p, "missing", true).unwrap();
    let failed = wait(&mut c, &["failed"]);
    assert!(failed["error"].as_str().unwrap().contains("unavailable"));
    assert!(store.voice_snapshot().unwrap()["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    c.cancel(failed["id"].as_str().unwrap(), p).unwrap();
    assert_eq!(
        std::fs::read_dir(tmp.path().join("drafts"))
            .unwrap()
            .count(),
        1
    );
}
#[test]
fn restarting_removes_abandoned_drafts_and_another_owner_cannot_clean_them() {
    let (tmp, _store, _p, c) = setup();
    let folder = tmp.path().join("drafts/draft-abandoned");
    std::fs::create_dir(&folder).unwrap();
    std::fs::write(folder.join("000000.wav"), b"private draft").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/voice_capture.py");
    assert!(VoiceCapture::new(tmp.path().join("drafts"), helper.clone()).is_err());
    assert!(folder.exists());
    drop(c);
    let _new = VoiceCapture::new(tmp.path().join("drafts"), helper).unwrap();
    assert!(!folder.exists());
}
#[test]
fn demo_participants_and_unknown_ids_cannot_start_capture() {
    let (_tmp, store, _p, mut c) = setup();
    let w = store.workspace_action(&json!({"op":"seed_demo"})).unwrap();
    let _ = w;
    let demo = store.workspace(true, None).unwrap()["people"][0]["id"]
        .as_i64()
        .unwrap();
    assert!(c.start(&store, demo, "", true).is_err());
    assert!(c.start(&store, 99999, "", true).is_err());
    assert!(!c.busy());
}

#[test]
fn sample_and_meeting_cannot_use_the_same_microphone_concurrently() {
    let (tmp, store, p, mut sample) = setup();
    let s = sample.start(&store, p, "", true).unwrap();
    let id = s["draft"]["id"].as_str().unwrap();
    wait(&mut sample, &["recording"]);
    let meeting = store.create_meeting("Capture ownership test").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut capture = vtracker::capture::CaptureManager::new(helper, tmp.path().join("audio"));
    assert!(capture.start(&store, meeting, 2).is_err());
    assert_eq!(
        store.export(meeting).unwrap()["meeting"]["status"],
        "created"
    );
    sample.cancel(id, p).unwrap();
    capture.start(&store, meeting, 2).unwrap();
    assert!(sample.start(&store, p, "", true).is_err());
    capture.stop(meeting).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !capture.status()["active"].is_null() {
        capture.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    sample.start(&store, p, "", true).unwrap();
    sample.discard_person(p).unwrap();
}
