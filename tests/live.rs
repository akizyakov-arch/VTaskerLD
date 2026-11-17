#![cfg(unix)]
use std::{
    path::{Path, PathBuf},
    process::Command,
};
use vtracker::{speech::SpeechConfig, Store};

fn setup(count: u32) -> (tempfile::TempDir, Store, i64, String, SpeechConfig) {
    let tmp = tempfile::tempdir().unwrap();
    let db = tmp.path().join("db");
    let store = Store::open(&db).unwrap();
    let meeting = store.create_meeting("Live test").unwrap();
    let session = format!("{meeting}-123");
    let source = tmp.path().join("input.wav");
    let mut wav = hound::WavWriter::create(
        &source,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for _ in 0..16000 {
        wav.write_sample(0i16).unwrap();
    }
    wav.finalize().unwrap();
    for sequence in 0..count {
        store
            .import_fragment(
                meeting,
                &session,
                sequence,
                &source,
                &tmp.path().join("audio"),
            )
            .unwrap();
    }
    let model = tmp.path().join("model");
    std::fs::write(&model, b"FIXTURE MODEL").unwrap();
    let config = SpeechConfig {
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/whisper.py"),
        model,
        ffmpeg: vtracker::speech::resolve(Path::new("ffmpeg")).unwrap(),
        language: "ru".into(),
        vad_model: None,
        diarization: None,
    };
    let c = rusqlite::Connection::open(db).unwrap();
    c.execute(
        "UPDATE meetings SET status='recording' WHERE id=?1",
        [meeting],
    )
    .unwrap();
    store
        .start_live(meeting, &session, &config.model, "ru")
        .unwrap();
    (tmp, store, meeting, session, config)
}

#[test]
fn live_has_absolute_times_and_does_not_publish_a_final_transcript() {
    let (tmp, store, meeting, session, config) = setup(2);
    store.queue_live(&session).unwrap();
    for index in 0..2 {
        let snap = store.live_snapshot(meeting).unwrap();
        let id = snap["chunks"][index]["id"].as_i64().unwrap();
        let scratch = tempfile::tempdir().unwrap();
        let status = Command::new(env!("CARGO_BIN_EXE_vtracker"))
            .arg("--db")
            .arg(tmp.path().join("db"))
            .arg("live-chunk")
            .arg(id.to_string())
            .arg("--scratch")
            .arg(scratch.path())
            .env("VTRACKER_WHISPER_BIN", &config.engine)
            .env("VTRACKER_WHISPER_MODEL", &config.model)
            .env("VTRACKER_FFMPEG_BIN", &config.ffmpeg)
            .env_remove("VTRACKER_DIARIZATION_BIN")
            .env_remove("VTRACKER_SEGMENTATION_MODEL")
            .env_remove("VTRACKER_EMBEDDING_MODEL")
            .status()
            .unwrap();
        assert!(status.success());
    }
    let snapshot = store.live_snapshot(meeting).unwrap();
    assert_eq!(snapshot["status"], "preliminary");
    assert_eq!(snapshot["chunks"][0]["segments"][0]["start_ms"], 0);
    assert_eq!(snapshot["chunks"][1]["segments"][0]["start_ms"], 1000);
    assert_eq!(snapshot["chunks"][1]["segments"][0]["end_ms"], 2000);
    assert_eq!(
        snapshot["chunks"][1]["segments"][0]["sources"][0]["start_ms"],
        1000
    );
    assert!(store.transcript(meeting).unwrap().is_null());
    assert_eq!(store.meetings().unwrap()[0]["status"], "recording");
    assert_eq!(
        store.recordings(meeting).unwrap().as_array().unwrap().len(),
        1
    ); // identical silence deduplicated
}

#[test]
fn backlog_is_bounded_and_defers_without_losing_audio() {
    let (_tmp, store, meeting, session, _config) = setup(7);
    store.queue_live(&session).unwrap();
    let snapshot = store.live_snapshot(meeting).unwrap();
    assert_eq!(snapshot["state"], "deferred");
    assert!(snapshot["chunks"].as_array().unwrap().len() <= vtracker::live::QUEUE_LIMIT as usize);
    assert_eq!(
        store.fragments(meeting).unwrap().as_array().unwrap().len(),
        7
    );
    assert_eq!(store.meetings().unwrap()[0]["status"], "recording");
}

#[test]
fn malformed_live_result_keeps_recording_and_allows_final_processing() {
    let (tmp, store, meeting, session, config) = setup(1);
    std::fs::write(&config.model, b"BAD_JSON").unwrap();
    store.queue_live(&session).unwrap();
    let id = store.live_snapshot(meeting).unwrap()["chunks"][0]["id"]
        .as_i64()
        .unwrap();
    let scratch = tempfile::tempdir().unwrap();
    assert!(store.run_live_chunk(id, config, scratch.path()).is_err());
    assert_eq!(store.live_snapshot(meeting).unwrap()["state"], "deferred");
    assert_eq!(
        store.live_snapshot(meeting).unwrap()["chunks"][0]["state"],
        "failed"
    );
    assert_eq!(store.meetings().unwrap()[0]["status"], "recording");
    assert!(!store.live_busy().unwrap());
    assert_eq!(
        store.fragments(meeting).unwrap().as_array().unwrap().len(),
        1
    );
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute(
        "UPDATE meetings SET status='completed' WHERE id=?1",
        [meeting],
    )
    .unwrap();
    let model = tmp.path().join("model");
    std::fs::write(&model, b"GOOD").unwrap();
    let config = SpeechConfig {
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/whisper.py"),
        model,
        ffmpeg: vtracker::speech::resolve(Path::new("ffmpeg")).unwrap(),
        language: "ru".into(),
        vad_model: None,
        diarization: None,
    };
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    assert_eq!(store.transcript(meeting).unwrap()["status"], "final");
}

#[test]
fn unfinished_live_worker_blocks_final_inference_until_explicit_recovery() {
    let (tmp, store, meeting, session, config) = setup(1);
    store.queue_live(&session).unwrap();
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute("UPDATE live_chunks SET state='running'", [])
        .unwrap();
    c.execute(
        "UPDATE meetings SET status='completed' WHERE id=?1",
        [meeting],
    )
    .unwrap();
    store.enqueue(meeting).unwrap();
    assert!(store.run_next(&config).is_err());
    store.recover_live(meeting).unwrap();
    assert!(!store.live_busy().unwrap());
    assert_eq!(store.run_next(&config).unwrap(), Some(1));
    assert_eq!(
        store.live_snapshot(meeting).unwrap()["state"],
        "interrupted"
    );
}

#[test]
fn stopping_live_preserves_preview_and_defers_remaining_fragments() {
    let (_tmp, store, meeting, session, config) = setup(2);
    store.queue_live(&session).unwrap();
    let id = store.live_snapshot(meeting).unwrap()["chunks"][0]["id"]
        .as_i64()
        .unwrap();
    store
        .run_live_chunk(id, config, tempfile::tempdir().unwrap().path())
        .unwrap();
    store.finish_live(&session).unwrap();
    let snapshot = store.live_snapshot(meeting).unwrap();
    assert_eq!(snapshot["state"], "finished");
    assert_eq!(snapshot["chunks"][0]["state"], "completed");
    assert_eq!(snapshot["chunks"][1]["state"], "deferred");
    assert!(!snapshot["chunks"][0]["segments"]
        .as_array()
        .unwrap()
        .is_empty());
    assert!(store.transcript(meeting).unwrap().is_null());
}
