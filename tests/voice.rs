#![cfg(unix)]
use std::path::{Path, PathBuf};
use vtracker::{voice::VoiceConfig, Store};
fn setup() -> (tempfile::TempDir, Store, i64, VoiceConfig) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let person = store.add_person("Voice test participant").unwrap();
    let model = tmp.path().join("model");
    std::fs::write(&model, b"model-a").unwrap();
    let config = VoiceConfig {
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/embedding.py"),
        model,
        ffmpeg: vtracker::speech::resolve(Path::new("ffmpeg")).unwrap(),
    };
    (tmp, store, person, config)
}
fn sample(path: &Path, quiet: bool) {
    let mut wav = hound::WavWriter::create(
        path,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for i in 0..128000 {
        wav.write_sample(if quiet {
            0i16
        } else {
            ((i % 100) as i16 - 50) * 200
        })
        .unwrap();
    }
    wav.finalize().unwrap();
}
#[test]
fn enrollment_requires_explicit_consent_and_single_speaker_confirmation() {
    let (tmp, store, person, _) = setup();
    let source = tmp.path().join("voice.wav");
    sample(&source, false);
    let root = tmp.path().join("voice");
    assert!(store
        .queue_voice_sample(person, &source, &root, false, true)
        .is_err());
    assert!(store
        .queue_voice_sample(person, &source, &root, true, false)
        .is_err());
    assert!(!root.exists());
    assert!(store.voice_snapshot().unwrap()["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn samples_create_versioned_profiles_without_exposing_embeddings() {
    let (tmp, store, person, config) = setup();
    let source = tmp.path().join("voice.wav");
    sample(&source, false);
    let root = tmp.path().join("voice");
    for count in 1..=2 {
        let id = store
            .queue_voice_sample(person, &source, &root, true, true)
            .unwrap();
        store
            .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
            .unwrap();
        let snapshot = store.voice_snapshot().unwrap();
        assert_eq!(snapshot["profiles"][0]["sample_count"], count);
        assert_eq!(snapshot["profiles"][0]["revision"], count);
        assert_eq!(snapshot["jobs"][0]["state"], "completed");
        assert!(!snapshot.to_string().contains("embedding_json"));
        assert!(!root.join(format!("pending-{id}.input")).exists());
    }
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    assert_eq!(
        c.query_row("SELECT count(*) FROM voice_profiles", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert_eq!(
        c.query_row("SELECT count(*) FROM voice_samples", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        2
    );
}
#[test]
fn different_embedding_model_versions_are_never_averaged_together() {
    let (tmp, store, person, config) = setup();
    let source = tmp.path().join("voice.wav");
    sample(&source, false);
    let root = tmp.path().join("voice");
    let id = store
        .queue_voice_sample(person, &source, &root, true, true)
        .unwrap();
    store
        .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
        .unwrap();
    std::fs::write(&config.model, b"model-b").unwrap();
    let id = store
        .queue_voice_sample(person, &source, &root, true, true)
        .unwrap();
    store
        .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
        .unwrap();
    let snapshot = store.voice_snapshot().unwrap();
    assert_eq!(snapshot["profiles"].as_array().unwrap().len(), 2);
    assert_eq!(snapshot["profiles"][0]["sample_count"], 1);
    assert_eq!(snapshot["profiles"][1]["sample_count"], 1);
    assert_ne!(
        snapshot["profiles"][0]["model_sha256"],
        snapshot["profiles"][1]["model_sha256"]
    );
}
#[test]
fn quiet_or_invalid_samples_do_not_create_a_profile() {
    let (tmp, store, person, config) = setup();
    let source = tmp.path().join("voice.wav");
    sample(&source, true);
    let root = tmp.path().join("voice");
    let id = store
        .queue_voice_sample(person, &source, &root, true, true)
        .unwrap();
    assert!(store
        .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
        .is_err());
    assert!(store.voice_snapshot().unwrap()["profiles"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        store.voice_snapshot().unwrap()["jobs"][0]["state"],
        "failed"
    );
    sample(&source, false);
    std::fs::write(&config.model, b"invalid").unwrap();
    let id = store
        .queue_voice_sample(person, &source, &root, true, true)
        .unwrap();
    assert!(store
        .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
        .is_err());
    assert!(store.voice_snapshot().unwrap()["profiles"]
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn deleting_biometrics_keeps_people_and_meeting_history_and_revokes_consents() {
    let (tmp, store, person, config) = setup();
    let meeting = store.create_meeting("History stays").unwrap();
    let source = tmp.path().join("voice.wav");
    sample(&source, false);
    let root = tmp.path().join("voice");
    let id = store
        .queue_voice_sample(person, &source, &root, true, true)
        .unwrap();
    store
        .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
        .unwrap();
    assert!(store.delete_voice(person, &root, false).is_err());
    assert!(root.join(format!("sample-{id}.wav")).exists());
    store.delete_voice(person, &root, true).unwrap();
    assert!(!root.join(format!("sample-{id}.wav")).exists());
    assert!(store.voice_snapshot().unwrap()["profiles"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(store.people().unwrap()[0]["id"], person);
    assert_eq!(
        store.export(meeting).unwrap()["meeting"]["title"],
        "History stays"
    );
    assert!(source.exists());
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    assert_eq!(
        c.query_row(
            "SELECT count(*) FROM voice_consents WHERE revoked_at IS NOT NULL",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
}
#[test]
fn enrollment_waits_for_recording_without_changing_its_state() {
    let (tmp, store, person, config) = setup();
    let meeting = store.create_meeting("Recording").unwrap();
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute(
        "UPDATE meetings SET status='recording' WHERE id=?1",
        [meeting],
    )
    .unwrap();
    let source = tmp.path().join("voice.wav");
    sample(&source, false);
    let root = tmp.path().join("voice");
    let id = store
        .queue_voice_sample(person, &source, &root, true, true)
        .unwrap();
    assert!(store
        .run_voice_job(id, &root, tempfile::tempdir().unwrap().path(), &config)
        .is_err());
    assert_eq!(
        store.voice_snapshot().unwrap()["jobs"][0]["state"],
        "pending"
    );
    assert_eq!(store.meetings().unwrap()[0]["status"], "recording");
}

#[test]
fn queued_samples_reserve_slots_per_participant() {
    let (tmp, store, person, config) = setup();
    let other = store.add_person("Other participant").unwrap();
    let input = tmp.path().join("sample.wav");
    sample(&input, false);
    let root = tmp.path().join("voice");

    for _ in 0..2 {
        let id = store.queue_voice_sample(person, &input, &root, true, true).unwrap();
        let scratch = tempfile::tempdir().unwrap();
        store.run_voice_job(id, &root, scratch.path(), &config).unwrap();
    }
    store.queue_voice_sample(person, &input, &root, true, true).unwrap();
    let error = store.queue_voice_sample(person, &input, &root, true, true).unwrap_err();
    assert!(error.to_string().contains("до 3 голосовых образцов"));
    store.queue_voice_sample(other, &input, &root, true, true).unwrap();
}
