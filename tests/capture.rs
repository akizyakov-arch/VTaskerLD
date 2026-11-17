#![cfg(unix)]
use std::path::PathBuf;
use std::time::{Duration, Instant};
use vtracker::{capture::CaptureManager, Store};

#[test]
fn capture_stop_imports_audio_and_prevents_competing_owners() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let first = store.create_meeting("First").unwrap();
    let second = store.create_meeting("Second").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut manager = CaptureManager::new(helper.clone(), tmp.path().join("audio"));
    manager.start(&store, first, 60).unwrap();
    assert!(manager.start(&store, second, 60).is_err());
    let mut competing = CaptureManager::new(helper, tmp.path().join("other"));
    assert!(competing.start(&store, second, 60).is_err());
    assert!(manager.stop(second).is_err());
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        manager.poll(&store).unwrap();
        if manager.status()["active"]["state"] == "recording" {
            break;
        }
        assert!(Instant::now() < deadline, "helper did not become ready");
        std::thread::sleep(Duration::from_millis(20));
    }
    while store
        .fragments(first)
        .unwrap()
        .as_array()
        .unwrap()
        .is_empty()
    {
        manager.poll(&store).unwrap();
        assert!(
            Instant::now() < deadline,
            "first fragment was not saved during capture"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        store.export(first).unwrap()["meeting"]["status"],
        "recording"
    );
    manager.stop(first).unwrap();
    manager.stop(first).unwrap();
    while !manager.status()["active"].is_null() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline, "helper did not stop");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(manager.status()["last"]["state"], "completed");
    assert_eq!(
        store.export(first).unwrap()["meeting"]["status"],
        "completed"
    );
    assert_eq!(
        store.recordings(first).unwrap().as_array().unwrap().len(),
        1
    );
    let fragments = store.fragments(first).unwrap();
    assert_eq!(fragments.as_array().unwrap().len(), 2);
    assert_eq!(fragments[0]["start_frame"], 0);
    assert_eq!(fragments[1]["start_frame"], 1600);
    assert_eq!(fragments[0]["recording_id"], fragments[1]["recording_id"]);
    assert_eq!(manager.status()["last"]["fragments"], 2);
    assert!(manager.start(&store, first, 60).is_err());
}
#[test]
fn missing_or_unlaunchable_helper_never_leaves_meeting_recording() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let id = store.create_meeting("Test").unwrap();
    let mut manager = CaptureManager::new(tmp.path().join("missing"), tmp.path().join("audio"));
    assert!(manager.start(&store, id, 60).is_err());
    assert_eq!(store.export(id).unwrap()["meeting"]["status"], "created");
    let invalid = tmp.path().join("invalid");
    std::fs::write(&invalid, b"not executable").unwrap();
    let mut manager = CaptureManager::new(invalid, tmp.path().join("audio"));
    assert!(manager.start(&store, id, 60).is_err());
    assert_eq!(store.export(id).unwrap()["meeting"]["status"], "failed");
}
#[test]
fn helper_failure_is_reported_without_claiming_recording_exists() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let id = store.create_meeting("Failure").unwrap();
    let mut manager =
        CaptureManager::new(PathBuf::from("/usr/bin/false"), tmp.path().join("audio"));
    manager.start(&store, id, 60).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !manager.status()["active"].is_null() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(manager.status()["last"]["state"], "failed");
    assert_eq!(store.export(id).unwrap()["meeting"]["status"], "failed");
    assert_eq!(store.recordings(id).unwrap(), serde_json::json!([]));
}

#[test]
fn abrupt_helper_loss_preserves_already_published_audio() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("db");
    let root = tmp.path().join("audio");
    let store = Store::open(&path).unwrap();
    let id = store.create_meeting("Interrupted").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut manager = CaptureManager::new(helper, root.clone());
    manager.start(&store, id, 60).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while store.fragments(id).unwrap().as_array().unwrap().is_empty() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
    // Drop simulates abrupt server teardown; it kills and reaps its helper.
    drop(manager);
    assert_eq!(store.fragments(id).unwrap().as_array().unwrap().len(), 1);
    assert!(store.recover_capture(id, &root).is_err());
    store.interrupt_capture(id).unwrap();
    assert_eq!(store.recover_capture(id, &root).unwrap(), 1);
    assert_eq!(store.export(id).unwrap()["meeting"]["status"], "failed");
    assert_eq!(store.fragments(id).unwrap().as_array().unwrap().len(), 1);
}

#[test]
fn microphone_failure_keeps_completed_fragments_and_reports_last_saved_time() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let id = store.create_meeting("Disconnected").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture_fail.py");
    let mut manager = CaptureManager::new(helper, tmp.path().join("audio"));
    manager.start(&store, id, 60).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !manager.status()["active"].is_null() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
    let state = manager.status();
    assert_eq!(state["last"]["state"], "failed");
    assert_eq!(state["last"]["saved_ms"], 100);
    assert!(state["last"]["error"]
        .as_str()
        .unwrap()
        .contains("disconnected"));
    assert_eq!(store.recordings(id).unwrap().as_array().unwrap().len(), 1);
}

#[test]
fn selected_microphone_metadata_survives_capture_and_recovery() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let meeting = store.create_meeting("Selected device").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let root = tmp.path().join("audio");
    let mut manager = CaptureManager::new(helper.clone(), root.clone());
    assert_eq!(
        vtracker::capture::devices(&helper).unwrap()[0]["uid"],
        "test-mic"
    );
    manager
        .start_device(&store, meeting, 60, "test-mic")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while manager.status()["active"]["state"] != "recording" {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(manager.status()["active"]["source"], "Synthetic microphone");
    manager.stop(meeting).unwrap();
    while !manager.status()["active"].is_null() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        store.fragments(meeting).unwrap()[0]["device"]["uid"],
        "test-mic"
    );
    assert!(store.recover_capture(meeting, &root).unwrap() > 0);
    assert_eq!(
        store.export(meeting).unwrap()["fragments"][0]["device"]["name"],
        "Synthetic microphone"
    );
}

#[test]
fn microphone_test_reads_levels_without_saving_audio_or_creating_meetings() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut test = vtracker::capture::MicrophoneTest::default();
    assert!(test.start(&helper, "test-mic", 31).is_err());
    test.start(&helper, "test-mic", 1).unwrap();
    assert!(test.start(&helper, "test-mic", 1).is_err());
    let deadline = Instant::now() + Duration::from_secs(5);
    while test.active() {
        test.poll().unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(test.status()["state"], "completed");
    assert_eq!(test.status()["peak"], 0.25);
    assert_eq!(test.status()["device"]["uid"], "test-mic");
    assert!(store.meetings().unwrap().as_array().unwrap().is_empty());
    assert!(!tmp.path().join("audio").exists());
}

#[test]
fn unavailable_selected_microphone_never_falls_back_to_another_device() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let meeting = store.create_meeting("Disconnected microphone").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut manager = CaptureManager::new(helper, tmp.path().join("audio"));
    manager
        .start_device(&store, meeting, 5, "disconnected")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !manager.status()["active"].is_null() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(manager.status()["last"]["state"], "failed");
    assert!(store
        .recordings(meeting)
        .unwrap()
        .as_array()
        .unwrap()
        .is_empty());
}

fn finish_short_capture(manager: &mut CaptureManager, store: &Store, meeting: i64) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while manager.status()["active"]["state"] != "recording"
        || manager.status()["active"]["fragments"]
            .as_u64()
            .unwrap_or(0)
            == 0
    {
        manager.poll(store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    manager.stop(meeting).unwrap();
    while !manager.status()["active"].is_null() {
        manager.poll(store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(manager.status()["last"]["state"], "completed");
}

#[test]
fn continue_meeting_appends_occurrences_and_preserves_the_old_transcript() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let meeting = store.create_meeting("Continue").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut manager = CaptureManager::new(helper, tmp.path().join("audio"));
    manager.start(&store, meeting, 60).unwrap();
    finish_short_capture(&mut manager, &store, meeting);
    let model = tmp.path().join("model");
    std::fs::write(&model, b"fixture").unwrap();
    let config = vtracker::speech::SpeechConfig {
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/whisper.py"),
        model,
        ffmpeg: vtracker::speech::resolve(std::path::Path::new("ffmpeg")).unwrap(),
        language: "ru".into(),
        diarization: None,
        vad_model: None,
    };
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let old = store.transcript(meeting).unwrap();
    let before = store.recordings(meeting).unwrap();
    let path = before[0]["path"].as_str().unwrap();
    let bytes = std::fs::read(path).unwrap();
    assert!(
        !store.export(meeting).unwrap()["transcript"]["needs_update"]
            .as_bool()
            .unwrap()
    );
    manager.continue_device(&store, meeting, 60, "").unwrap();
    let session = manager.status()["active"]["session_id"]
        .as_str()
        .unwrap()
        .to_string();
    store
        .start_live(meeting, &session, &config.model, "ru")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while manager.status()["active"]["fragments"]
        .as_u64()
        .unwrap_or(0)
        == 0
    {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    store.queue_live(&session).unwrap();
    assert_eq!(
        store.live_snapshot(meeting).unwrap()["chunks"][0]["start_ms"],
        200
    );
    finish_short_capture(&mut manager, &store, meeting);
    store.finish_live(&session).unwrap();
    assert_eq!(store.audio_inputs(meeting).unwrap().len(), 4);
    assert_eq!(manager.status()["last"]["saved_ms"], 400);
    assert_eq!(store.transcript(meeting).unwrap(), old);
    assert_eq!(std::fs::read(path).unwrap(), bytes);
    assert!(store.export(meeting).unwrap()["transcript"]["needs_update"]
        .as_bool()
        .unwrap());
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    assert_eq!(
        store.transcript(meeting).unwrap()["segments"][0]["end_ms"],
        400
    );
    assert!(
        !store.export(meeting).unwrap()["transcript"]["needs_update"]
            .as_bool()
            .unwrap()
    );
}

#[test]
fn continuation_keeps_import_before_new_capture_and_refuses_pending_processing() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let meeting = store.create_meeting("Imported").unwrap();
    let input = tmp.path().join("import.wav");
    let mut wav = hound::WavWriter::create(
        &input,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for _ in 0..16000 {
        wav.write_sample(10i16).unwrap();
    }
    wav.finalize().unwrap();
    store
        .import_wav(meeting, &input, &tmp.path().join("audio"))
        .unwrap();
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute(
        "UPDATE meetings SET status='completed' WHERE id=?1",
        [meeting],
    )
    .unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut manager = CaptureManager::new(helper, tmp.path().join("audio"));
    manager.continue_device(&store, meeting, 60, "").unwrap();
    finish_short_capture(&mut manager, &store, meeting);
    let timeline = store.audio_inputs(meeting).unwrap();
    assert!(timeline[0]["session_id"].is_null());
    assert_eq!(timeline[1]["start_ms"], 1000);
    assert_eq!(timeline.last().unwrap()["end_ms"], 1200);
    store.enqueue(meeting).unwrap();
    assert!(manager.continue_device(&store, meeting, 60, "").is_err());
    assert_eq!(store.meetings().unwrap()[0]["status"], "completed");
}

#[test]
fn failed_continuation_keeps_the_preceding_audio_available() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let meeting = store.create_meeting("Continue failure").unwrap();
    let helper = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/capture.py");
    let mut manager = CaptureManager::new(helper, tmp.path().join("audio"));
    manager.start(&store, meeting, 60).unwrap();
    finish_short_capture(&mut manager, &store, meeting);
    let before = store.audio_inputs(meeting).unwrap();
    manager
        .continue_device(&store, meeting, 5, "disconnected")
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !manager.status()["active"].is_null() {
        manager.poll(&store).unwrap();
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(manager.status()["last"]["state"], "failed");
    assert_eq!(store.audio_inputs(meeting).unwrap(), before);
    assert_eq!(store.meetings().unwrap()[0]["status"], "failed");
}
