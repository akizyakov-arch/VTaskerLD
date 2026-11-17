#![cfg(unix)]
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use vtracker::{diarization::DiarizationConfig, speech::SpeechConfig, voice::VoiceConfig, Store};
fn setup() -> (
    tempfile::TempDir,
    Store,
    i64,
    i64,
    SpeechConfig,
    VoiceConfig,
) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let person = store.add_person("Registered participant").unwrap();
    let meeting = store.create_meeting("Known voice").unwrap();
    let sample = tmp.path().join("speech.wav");
    let mut wav = hound::WavWriter::create(
        &sample,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .unwrap();
    for i in 0..320000 {
        wav.write_sample(((i % 100) as i16 - 50) * 200).unwrap();
    }
    wav.finalize().unwrap();
    store
        .import_wav(meeting, &sample, &tmp.path().join("audio"))
        .unwrap();
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let model = tmp.path().join("model");
    std::fs::write(&model, b"model-a").unwrap();
    let segmentation = tmp.path().join("segmentation");
    std::fs::write(&segmentation, b"fixture").unwrap();
    let config = SpeechConfig {
        engine: fixture.join("whisper.py"),
        model: model.clone(),
        ffmpeg: vtracker::speech::resolve(Path::new("ffmpeg")).unwrap(),
        language: "ru".into(),
        vad_model: None,
        diarization: Some(DiarizationConfig {
        cluster_threshold: None,
            engine: fixture.join("diarize.py"),
            segmentation,
            embedding: model.clone(),
            speakers: 1,
        }),
    };
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let run = store.transcript(meeting).unwrap()["model_run_id"]
        .as_i64()
        .unwrap();
    let voice = VoiceConfig {
        engine: fixture.join("embedding.py"),
        model,
        ffmpeg: vtracker::speech::resolve(Path::new("ffmpeg")).unwrap(),
    };
    (tmp, store, person, run, config, voice)
}
fn enroll(tmp: &tempfile::TempDir, store: &Store, person: i64, voice: &VoiceConfig) {
    let id = store
        .queue_voice_sample(
            person,
            &tmp.path().join("speech.wav"),
            &tmp.path().join("voice"),
            true,
            true,
        )
        .unwrap();
    store
        .run_voice_job(
            id,
            &tmp.path().join("voice"),
            tempfile::tempdir().unwrap().path(),
            voice,
        )
        .unwrap();
}
fn matches(store: &Store, run: i64, voice: &VoiceConfig) -> Value {
    let job = store.queue_voice_matching(run).unwrap();
    store
        .run_voice_matching(job, tempfile::tempdir().unwrap().path(), voice)
        .unwrap();
    store.voice_matches(run).unwrap()
}
#[test]
fn meeting_enrollment_excludes_overlap_and_records_consent_provenance() {
    let (tmp, store, person, run, _config, voice) = setup();
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute("INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id) VALUES (?1,6000,12000,'speaker_1')",[run]).unwrap();
    let plan = store.voice_source_plan(run, "speaker_0").unwrap();
    assert_eq!(plan["duration_ms"], 14000);
    assert_eq!(
        plan["intervals"],
        json!([{"start_ms":0,"end_ms":6000},{"start_ms":12000,"end_ms":20000}])
    );
    assert!(store
        .queue_voice_from_meeting(person, run, "speaker_0", false, true)
        .is_err());
    let job = store
        .queue_voice_from_meeting(person, run, "speaker_0", true, true)
        .unwrap();
    store
        .run_voice_job(
            job,
            &tmp.path().join("voice"),
            tempfile::tempdir().unwrap().path(),
            &voice,
        )
        .unwrap();
    assert_eq!(
        store.voice_snapshot().unwrap()["profiles"][0]["sample_count"],
        1
    );
    let raw: String = c
        .query_row(
            "SELECT source_json FROM voice_consents WHERE person_id=?1",
            [person],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&raw).unwrap(), plan);
    assert_eq!(
        hound::WavReader::open(tmp.path().join("voice").join(format!("sample-{job}.wav")))
            .unwrap()
            .duration(),
        224000
    );
}
#[test]
fn too_short_clean_speech_is_rejected_without_a_consent_or_job() {
    let (tmp, store, person, run, _config, _voice) = setup();
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute(
        "UPDATE speaker_turns SET end_ms=5000 WHERE model_run_id=?1",
        [run],
    )
    .unwrap();
    assert!(store.voice_source_plan(run, "speaker_0").is_err());
    assert!(store
        .queue_voice_from_meeting(person, run, "speaker_0", true, true)
        .is_err());
    assert_eq!(
        c.query_row("SELECT count(*) FROM voice_consents", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(store.voice_snapshot().unwrap()["jobs"]
        .as_array()
        .unwrap()
        .is_empty());
}
#[test]
fn strong_match_is_only_a_suggestion_and_manual_assignments_take_priority() {
    let (tmp, store, person, run, _config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    let results = matches(&store, run, &voice);
    assert_eq!(results[0]["status"], "candidate");
    assert_eq!(results[0]["person_id"], person);
    assert!(results[0]["similarity"].as_f64().unwrap() > 0.999);
    let transcript = store.transcript(1).unwrap();
    assert!(transcript["segments"][0]["person_id"].is_null());
    assert_eq!(
        transcript["segments"][0]["voice_suggestion"]["person_id"],
        person
    );
    assert!(store.speaker_assignments(run, true).unwrap().is_empty());
    store.assign_speaker(run, "speaker_0", None).unwrap();
    let transcript = store.transcript(1).unwrap();
    assert_eq!(
        transcript["segments"][0]["assignment_source"],
        "manual_speaker"
    );
    assert!(transcript["segments"][0]["voice_suggestion"].is_null());
    store
        .assign_speaker(run, "speaker_0", Some(person))
        .unwrap();
    assert_eq!(
        store.transcript(1).unwrap()["segments"][0]["person_id"],
        person
    );
}
#[test]
fn ambiguous_or_low_similarity_never_guesses_a_name() {
    let (tmp, store, person, run, _config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    let second = store.add_person("Similar voice").unwrap();
    enroll(&tmp, &store, second, &voice);
    let result = matches(&store, run, &voice);
    assert_eq!(result[0]["status"], "unknown");
    assert!(result[0]["person_id"].is_null());
    assert!(result[0]["reason"].as_str().unwrap().contains("отрыв"));
    store
        .delete_voice(second, &tmp.path().join("voice"), true)
        .unwrap();
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    c.execute("UPDATE voice_profiles SET embedding_json='[0,1,0,0]'", [])
        .unwrap();
    let result = matches(&store, run, &voice);
    assert_eq!(result[0]["status"], "unknown");
    assert!(result[0]["reason"].as_str().unwrap().contains("порога"));
}
#[test]
fn incompatible_models_and_deleted_profiles_do_not_leave_identity_suggestions() {
    let (tmp, store, person, run, _config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    matches(&store, run, &voice);
    store
        .assign_speaker(run, "speaker_0", Some(person))
        .unwrap();
    store
        .delete_voice(person, &tmp.path().join("voice"), true)
        .unwrap();
    assert!(store
        .voice_matches(run)
        .unwrap()
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        store.transcript(1).unwrap()["segments"][0]["person_id"],
        person
    );
    enroll(&tmp, &store, person, &voice);
    std::fs::write(&voice.model, b"model-b").unwrap();
    let result = matches(&store, run, &voice);
    assert_eq!(result[0]["status"], "unknown");
    assert!(result[0]["reason"]
        .as_str()
        .unwrap()
        .contains("совместимых"));
}
#[test]
fn failed_matching_preserves_previous_results_and_never_fails_transcription() {
    let (tmp, store, person, run, _config, mut voice) = setup();
    enroll(&tmp, &store, person, &voice);
    let previous = matches(&store, run, &voice);
    voice.model = tmp.path().join("missing-model");
    let job = store.queue_voice_matching(run).unwrap();
    assert!(store
        .run_voice_matching(job, tempfile::tempdir().unwrap().path(), &voice)
        .is_err());
    assert_eq!(store.voice_matches(run).unwrap(), previous);
    assert_eq!(store.transcript(1).unwrap()["status"], "final");
}
#[test]
fn automatic_matching_is_opt_in_and_queued_only_after_final_commit() {
    let (tmp, store, person, _run, config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    assert!(store.voice_snapshot().unwrap()["match_jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    store
        .save_voice_matching_settings(&json!({"enabled":true,"threshold":0.75,"margin":0.1}))
        .unwrap();
    store.enqueue(1).unwrap();
    store.run_next(&config).unwrap();
    let snapshot = store.voice_snapshot().unwrap();
    assert_eq!(snapshot["match_jobs"][0]["state"], "pending");
    assert_eq!(
        snapshot["match_jobs"][0]["model_run_id"],
        store.transcript(1).unwrap()["model_run_id"]
    );
    assert_eq!(store.transcript(1).unwrap()["status"], "final");
    assert!(!store.voice_busy().unwrap());
    assert!(store
        .save_voice_matching_settings(&json!({"enabled":true,"threshold":1.2,"margin":0.1}))
        .is_err());
}
