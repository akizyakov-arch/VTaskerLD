#![cfg(unix)]
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    thread,
    time::{Duration, Instant},
};
use vtracker::{live_voice::LiveVoiceWorker, voice::VoiceConfig, Store};
fn setup() -> (tempfile::TempDir, Store, i64, i64, VoiceConfig, Value) {
    let d = tempfile::tempdir().unwrap();
    let s = Store::open(&d.path().join("db")).unwrap();
    let person = s.add_person("Participant A").unwrap();
    let m = s
        .workspace_action(
            &json!({"op":"save_meeting","data":{"title":"Live voice","participants":[person]}}),
        )
        .unwrap()["id"]
        .as_i64()
        .unwrap();
    let sample = d.path().join("sample.wav");
    let mut w = hound::WavWriter::create(
        &sample,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for i in 0..160000 {
        w.write_sample(((i % 100) as i16 - 50) * 200).unwrap();
    }
    w.finalize().unwrap();
    let model = d.path().join("model");
    std::fs::write(&model, b"model-a").unwrap();
    let config = VoiceConfig {
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/embedding.py"),
        model,
        ffmpeg: vtracker::speech::resolve(std::path::Path::new("ffmpeg")).unwrap(),
    };
    let job = s
        .queue_voice_sample(person, &sample, &d.path().join("voice"), true, true)
        .unwrap();
    s.run_voice_job(
        job,
        &d.path().join("voice"),
        tempfile::tempdir().unwrap().path(),
        &config,
    )
    .unwrap();
    let session = format!("{m}-123");
    let mut reader = hound::WavReader::open(&sample).unwrap();
    let frames = reader
        .samples::<i16>()
        .map(Result::unwrap)
        .collect::<Vec<_>>();
    for i in 0..2 {
        let path = d.path().join(format!("piece{i}.wav"));
        let mut w = hound::WavWriter::create(&path, reader.spec()).unwrap();
        for v in &frames[i * 80000..(i + 1) * 80000] {
            w.write_sample(*v).unwrap();
        }
        w.finalize().unwrap();
        s.import_fragment(m, &session, i as u32, &path, &d.path().join("audio"))
            .unwrap();
    }
    let active = json!({"meeting_id":m,"session_id":session,"state":"recording","saved_ms":10000,"level":0.2});
    (d, s, m, person, config, active)
}
fn ready(worker: &mut LiveVoiceWorker, db: &std::path::Path, s: &Store, a: &Value) -> Value {
    let begin = Instant::now();
    loop {
        worker.poll(db, s, a, true).unwrap();
        let status = worker.status();
        if !worker.busy() && !status["hint"].is_null() {
            return status;
        }
        assert!(begin.elapsed() < Duration::from_secs(5), "Hint timed out");
        thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn hints_are_local_tentative_and_never_assign_transcript_or_create_tasks() {
    let (d, s, _m, p, c, a) = setup();
    let mut w = LiveVoiceWorker::new(Some(c));
    let status = ready(&mut w, &d.path().join("db"), &s, &a);
    assert_eq!(status["hint"]["status"], "candidate");
    assert_eq!(status["hint"]["person_id"], p);
    assert!(!status.to_string().contains("embedding"));
    let data = s.workspace(false, None).unwrap();
    assert!(data["tasks"].as_array().unwrap().is_empty());
    let db = rusqlite::Connection::open(d.path().join("db")).unwrap();
    assert_eq!(
        db.query_row("SELECT count(*) FROM speaker_assignments", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(status["hint"]["start_ms"], 5000);
    assert_eq!(status["hint"]["end_ms"], 10000);
}
#[test]
fn pause_stop_and_other_meeting_clear_names() {
    let (d, s, _, _, c, a) = setup();
    let mut w = LiveVoiceWorker::new(Some(c));
    ready(&mut w, &d.path().join("db"), &s, &a);
    let mut paused = a.clone();
    paused["state"] = json!("paused");
    w.poll(&d.path().join("db"), &s, &paused, true).unwrap();
    assert!(w.status()["hint"].is_null());
    w.poll(&d.path().join("db"), &s, &Value::Null, true)
        .unwrap();
    assert!(w.status()["hint"].is_null());
}
#[test]
fn competing_identical_profiles_are_unknown() {
    let (d, s, m, _, c, a) = setup();
    let second = s.add_person("Participant B").unwrap();
    let job = s
        .queue_voice_sample(
            second,
            &d.path().join("sample.wav"),
            &d.path().join("voice"),
            true,
            true,
        )
        .unwrap();
    s.run_voice_job(
        job,
        &d.path().join("voice"),
        tempfile::tempdir().unwrap().path(),
        &c,
    )
    .unwrap();
    let db = rusqlite::Connection::open(d.path().join("db")).unwrap();
    db.execute(
        "INSERT INTO meeting_people(meeting_id,person_id) VALUES (?1,?2)",
        [m, second],
    )
    .unwrap();
    let mut w = LiveVoiceWorker::new(Some(c));
    let status = ready(&mut w, &d.path().join("db"), &s, &a);
    assert_eq!(status["hint"]["status"], "unknown");
    assert!(status["hint"]["person_id"].is_null());
}
#[test]
fn people_outside_the_meeting_are_not_matched() {
    let (d, s, m, _, c, a) = setup();
    rusqlite::Connection::open(d.path().join("db"))
        .unwrap()
        .execute("DELETE FROM meeting_people WHERE meeting_id=?1", [m])
        .unwrap();
    let mut w = LiveVoiceWorker::new(Some(c));
    let status = ready(&mut w, &d.path().join("db"), &s, &a);
    assert_eq!(status["hint"]["status"], "unknown");
    assert!(!w.busy());
}
#[test]
fn failed_embedding_does_not_change_recording_state() {
    let (d, s, m, _, mut c, a) = setup();
    c.engine = "/usr/bin/false".into();
    let mut w = LiveVoiceWorker::new(Some(c));
    let status = ready(&mut w, &d.path().join("db"), &s, &a);
    assert_eq!(status["hint"]["status"], "unknown");
    assert_eq!(a["state"], "recording");
    assert_eq!(
        s.export(m).unwrap()["fragments"].as_array().unwrap().len(),
        2
    );
}

#[test]
fn revoked_consent_never_produces_a_name() {
    let (d, s, _, _, c, a) = setup();
    let mut w = LiveVoiceWorker::new(Some(c));
    w.poll(&d.path().join("db"), &s, &a, true).unwrap();
    rusqlite::Connection::open(d.path().join("db"))
        .unwrap()
        .execute(
            "UPDATE voice_consents SET revoked_at='2026-11-03T00:00:00Z'",
            [],
        )
        .unwrap();
    let status = ready(&mut w, &d.path().join("db"), &s, &a);
    assert_ne!(status["hint"]["status"], "candidate");
    assert!(status["hint"]["person_id"].is_null());
}

#[test]
#[ignore = "Requires installed local embedding model and a synthetic mono PCM16 16kHz WAV"]
fn real_local_embedding_generates_a_tentative_live_hint() {
    let source =
        PathBuf::from(std::env::var("VTASK_REAL_VOICE_SAMPLE").expect("Set a synthetic WAV path"));
    let mut r = hound::WavReader::open(source).unwrap();
    let spec = r.spec();
    assert_eq!(spec.sample_rate, 16000);
    assert_eq!(spec.channels, 1);
    let frames = r
        .samples::<i16>()
        .take(320000)
        .map(Result::unwrap)
        .collect::<Vec<_>>();
    assert_eq!(frames.len(), 320000);
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("db");
    let s = Store::open(&path).unwrap();
    let p = s.add_person("Synthetic test voice").unwrap();
    let m=s.workspace_action(&json!({"op":"save_meeting","data":{"title":"Real live model test","participants":[p]}})).unwrap()["id"].as_i64().unwrap();
    let sample = d.path().join("profile.wav");
    let mut w = hound::WavWriter::create(&sample, spec).unwrap();
    for v in &frames {
        w.write_sample(*v).unwrap();
    }
    w.finalize().unwrap();
    let c = VoiceConfig::from_env().unwrap();
    let job = s
        .queue_voice_sample(p, &sample, &d.path().join("voice"), true, true)
        .unwrap();
    s.run_voice_job(
        job,
        &d.path().join("voice"),
        tempfile::tempdir().unwrap().path(),
        &c,
    )
    .unwrap();
    let session = format!("{m}-900");
    for i in 0..2 {
        let piece = d.path().join(format!("{i}.wav"));
        let mut w = hound::WavWriter::create(&piece, spec).unwrap();
        for v in &frames[80000 + i * 80000..160000 + i * 80000] {
            w.write_sample(*v).unwrap();
        }
        w.finalize().unwrap();
        s.import_fragment(m, &session, i as u32, &piece, &d.path().join("audio"))
            .unwrap();
    }
    let a = json!({"meeting_id":m,"session_id":session,"state":"recording","saved_ms":10000,"level":0.2});
    let mut worker = LiveVoiceWorker::new(Some(c));
    let begin = Instant::now();
    let status = ready(&mut worker, &path, &s, &a);
    println!(
        "Real local live hint in {:.3}s: {}",
        begin.elapsed().as_secs_f64(),
        status
    );
    assert_eq!(status["hint"]["status"], "candidate");
    assert_eq!(status["hint"]["person_id"], p);
}
