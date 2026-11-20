#![cfg(unix)]
use std::path::PathBuf;
use vtracker::{speech::SpeechConfig, Store};
fn setup() -> (tempfile::TempDir, Store, i64, SpeechConfig) {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let meeting = store.create_meeting("Speech").unwrap();
    let source = tmp.path().join("input.wav");
    let mut writer = hound::WavWriter::create(
        &source,
        hound::WavSpec {
            channels: 2,
            sample_rate: 48000,
            bits_per_sample: 32,
            sample_format: hound::SampleFormat::Float,
        },
    )
    .unwrap();
    for _ in 0..9600 {
        writer.write_sample(0.0_f32).unwrap();
    }
    writer.finalize().unwrap();
    let root = tmp.path().join("audio");
    let session = format!("{meeting}-123");
    store
        .import_fragment(meeting, &session, 0, &source, &root)
        .unwrap();
    store
        .import_fragment(meeting, &session, 1, &source, &root)
        .unwrap();
    let model = tmp.path().join("fixture-model");
    std::fs::write(&model, b"NOT AN ML MODEL").unwrap();
    let config = SpeechConfig {
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/whisper.py"),
        model,
        ffmpeg: vtracker::speech::resolve(std::path::Path::new("ffmpeg")).unwrap(),
        language: "ru".into(),
        vad_model: None,
        diarization: None,
    };
    (tmp, store, meeting, config)
}
#[test]
fn disabling_speaker_detection_keeps_text_processing_with_missing_diarization_assets() {
    let (tmp, store, meeting, config) = setup();
    assert!(store.speaker_detection_enabled().unwrap());
    let conn = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    conn.execute(
        "INSERT INTO workspace_settings(key,data_json) VALUES ('speech',?1)",
        [r#"{"speaker_detection":false}"#],
    )
    .unwrap();
    store.enqueue(meeting).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_vtracker"))
        .arg("--db").arg(tmp.path().join("db")).args(["jobs", "run"])
        .env("VTRACKER_WHISPER_BIN", config.engine)
        .env("VTRACKER_WHISPER_MODEL", config.model)
        .env("VTRACKER_FFMPEG_BIN", config.ffmpeg)
        .env("VTRACKER_DIARIZATION_BIN", tmp.path().join("missing-diarization"))
        .env_remove("VTRACKER_WHISPER_WORKER")
        .env_remove("VTRACKER_VAD_MODEL")
        .env_remove("VTRACKER_CLOUD_URL")
        .output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let transcript = store.transcript(meeting).unwrap();
    assert_eq!(transcript["segments"][0]["text"], "Тестовый результат");
    assert_eq!(transcript["parameters"]["speaker_detection"], false);
    assert_eq!(transcript["speaker_turns"], serde_json::json!([]));
}

#[test]
fn transcript_has_timing_sources_and_failed_reprocessing_preserves_old_results() {
    let (_tmp, store, meeting, mut config) = setup();
    let job = store.enqueue(meeting).unwrap();
    assert_eq!(store.run_next(&config).unwrap(), Some(job));
    let first = store.transcript(meeting).unwrap();
    assert_eq!(first["segments"][0]["text"], "Тестовый результат");
    assert_eq!(first["segments"][0]["end_ms"], 200);
    assert_eq!(first["segments"][0]["sources"].as_array().unwrap().len(), 2);
    assert_eq!(store.jobs().unwrap()[0]["status"], "completed");
    assert_eq!(store.jobs().unwrap()[0]["attempts"], 1);
    let second_job = store.enqueue(meeting).unwrap();
    config.engine = "/usr/bin/false".into();
    assert!(store.run_next(&config).is_err());
    assert_eq!(store.transcript(meeting).unwrap(), first);
    assert_eq!(store.jobs().unwrap()[1]["status"], "failed");
    store.retry(second_job).unwrap();
    config.engine = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/whisper.py");
    store.run_next(&config).unwrap();
    assert_ne!(
        store.transcript(meeting).unwrap()["model_run_id"],
        first["model_run_id"]
    );
    assert_eq!(store.jobs().unwrap()[1]["attempts"], 2);
    assert!(store.run_next(&config).unwrap().is_none());
}
#[test]
fn corrupted_audio_is_rejected_and_job_can_be_retried() {
    let (_tmp, store, meeting, config) = setup();
    let job = store.enqueue(meeting).unwrap();
    let recordings = store.recordings(meeting).unwrap();
    std::fs::write(recordings[0]["path"].as_str().unwrap(), b"broken").unwrap();
    assert!(store
        .run_next(&config)
        .unwrap_err()
        .to_string()
        .contains("checksum"));
    assert_eq!(store.jobs().unwrap()[0]["status"], "failed");
    assert!(store.transcript(meeting).unwrap().is_null());
    store.retry(job).unwrap();
    assert_eq!(store.jobs().unwrap()[0]["status"], "pending");
}
#[test]
fn running_job_recovery_is_explicit() {
    let (tmp, store, meeting, _config) = setup();
    let job = store.enqueue(meeting).unwrap();
    let conn = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    conn.execute(
        "UPDATE processing_jobs SET status='running' WHERE id=?1",
        [job],
    )
    .unwrap();
    store.recover_job(job).unwrap();
    assert_eq!(store.jobs().unwrap()[0]["status"], "failed");
    assert!(store.recover_job(job).is_err());
}

#[test]
fn invalid_model_timestamps_do_not_publish_partial_transcripts() {
    let (_tmp, store, meeting, config) = setup();
    std::fs::write(&config.model, b"BAD_JSON").unwrap();
    store.enqueue(meeting).unwrap();
    assert!(store.run_next(&config).is_err());
    assert_eq!(store.jobs().unwrap()[0]["status"], "failed");
    assert!(store.transcript(meeting).unwrap().is_null());
}
#[test]
fn post_meeting_worker_defers_while_any_meeting_is_recording() {
    let (tmp, store, meeting, config) = setup();
    store.enqueue(meeting).unwrap();
    let other = store.create_meeting("Still recording").unwrap();
    let conn = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    conn.execute(
        "UPDATE meetings SET status='recording' WHERE id=?1",
        [other],
    )
    .unwrap();
    assert!(store.run_next(&config).is_err());
    assert_eq!(store.jobs().unwrap()[0]["status"], "pending");
    assert_eq!(store.jobs().unwrap()[0]["attempts"], 0);
}

#[test]
fn vad_configuration_is_forwarded_and_fingerprinted_per_run() {
    let (tmp, store, meeting, mut config) = setup();
    let vad = tmp.path().join("fixture-vad");
    std::fs::write(&vad, b"NOT A VAD MODEL").unwrap();
    config.vad_model = Some(vad.clone());
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let transcript = store.transcript(meeting).unwrap();
    assert_eq!(
        transcript["parameters"]["vad"]["model_path"],
        vad.to_str().unwrap()
    );
    assert_eq!(transcript["parameters"]["vad"]["threshold"], 0.5);
    assert_eq!(
        transcript["parameters"]["vad"]["sha256"]
            .as_str()
            .unwrap()
            .len(),
        64
    );
}
#[test]
fn missing_vad_model_does_not_consume_a_job() {
    let (tmp, store, meeting, mut config) = setup();
    config.vad_model = Some(tmp.path().join("missing-vad"));
    store.enqueue(meeting).unwrap();
    assert!(store.run_next(&config).is_err());
    assert_eq!(store.jobs().unwrap()[0]["status"], "pending");
    assert_eq!(store.jobs().unwrap()[0]["attempts"], 0);
}

#[test]
fn diarization_turns_are_versioned_and_failure_keeps_the_previous_result() {
    let (tmp, store, meeting, mut config) = setup();
    let segmentation = tmp.path().join("segmentation");
    let embedding = tmp.path().join("embedding");
    std::fs::write(&segmentation, b"NOT A SEGMENTATION MODEL").unwrap();
    std::fs::write(&embedding, b"NOT AN EMBEDDING MODEL").unwrap();
    config.diarization = Some(vtracker::diarization::DiarizationConfig {
        cluster_threshold: None,
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/diarize.py"),
        segmentation: segmentation.clone(),
        embedding,
        speakers: 0,
    });
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let first = store.transcript(meeting).unwrap();
    assert_eq!(first["speaker_turns"].as_array().unwrap().len(), 2);
    assert_eq!(first["segments"][0]["speaker_status"], "multiple");
    assert!(first["segments"][0]["speaker_id"].is_null());
    assert_eq!(first["parameters"]["diarization"]["num_speakers"], 0);
    assert!(vtracker::speech::transcript_text(&first).contains("[multiple]"));
    assert_eq!(first["parameters"]["cached_final_diarization"], false);
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let cached = store.transcript(meeting).unwrap();
    assert_eq!(cached["parameters"]["cached_final_diarization"], true);
    assert_eq!(cached["speaker_turns"], first["speaker_turns"]);

    config.diarization.as_mut().unwrap().speakers = 2;
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let changed_count = store.transcript(meeting).unwrap();
    assert_eq!(changed_count["parameters"]["diarization"]["num_speakers"], 2);
    assert_eq!(changed_count["parameters"]["cached_final_diarization"], false);
    std::fs::write(segmentation, b"FAIL").unwrap();
    store.enqueue(meeting).unwrap();
    assert!(store.run_next(&config).is_err());
    assert_eq!(store.transcript(meeting).unwrap(), changed_count);
    assert_eq!(store.jobs().unwrap()[3]["status"], "failed");
}

#[test]
fn manual_names_are_audited_and_do_not_leak_into_reprocessing() {
    let (tmp, store, meeting, mut config) = setup();
    let segmentation = tmp.path().join("seg");
    let embedding = tmp.path().join("emb");
    std::fs::write(&segmentation, b"fixture").unwrap();
    std::fs::write(&embedding, b"fixture").unwrap();
    config.diarization = Some(vtracker::diarization::DiarizationConfig {
        cluster_threshold: None,
        engine: PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/diarize.py"),
        segmentation,
        embedding,
        speakers: 0,
    });
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let run = store.transcript(meeting).unwrap()["model_run_id"]
        .as_i64()
        .unwrap();
    let anton = store.add_person("Антон").unwrap();
    let maria = store.add_person("Участник 2").unwrap();
    assert!(store
        .assign_speaker(run, "speaker_99", Some(anton))
        .is_err());
    assert!(store.assign_speaker(999, "speaker_0", Some(anton)).is_err());
    assert!(store.assign_speaker(run, "speaker_0", Some(999)).is_err());
    store.assign_speaker(run, "speaker_0", Some(anton)).unwrap();
    assert_eq!(
        store.transcript(meeting).unwrap()["speaker_turns"][0]["person_name"],
        "Антон"
    );
    // The mixed text segment remains unassigned even when a candidate has a name.
    assert!(store.transcript(meeting).unwrap()["segments"][0]["person_name"].is_null());
    store.assign_speaker(run, "speaker_0", Some(maria)).unwrap();
    assert_eq!(
        store.transcript(meeting).unwrap()["speaker_turns"][0]["person_name"],
        "Участник 2"
    );
    store.assign_speaker(run, "speaker_0", None).unwrap();
    assert!(store.transcript(meeting).unwrap()["speaker_turns"][0]["person_id"].is_null());
    assert_eq!(store.speaker_assignments(run, true).unwrap().len(), 3);
    store.assign_speaker(run, "speaker_0", Some(anton)).unwrap();
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let new = store.transcript(meeting).unwrap();
    assert_ne!(new["model_run_id"], run);
    assert!(new["speaker_turns"][0]["person_id"].is_null());
    assert_eq!(store.speaker_assignments(run, true).unwrap().len(), 4);
}

#[test]
fn per_fragment_corrections_preserve_model_text_and_explicit_person_scope() {
    let (_tmp, store, meeting, config) = setup();
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let original = store.transcript(meeting).unwrap();
    let run = original["model_run_id"].as_i64().unwrap();
    let segment = original["segments"][0]["id"].as_i64().unwrap();
    let person = store.add_person("Участник 1").unwrap();
    store
        .edit_segment(run, segment, "Исправленный текст")
        .unwrap();
    store.assign_segment(run, segment, Some(person)).unwrap();
    let corrected = store.transcript(meeting).unwrap();
    assert_eq!(corrected["segments"][0]["text"], "Исправленный текст");
    assert_eq!(
        corrected["segments"][0]["original_text"],
        "Тестовый результат"
    );
    assert_eq!(corrected["segments"][0]["person_name"], "Участник 1");
    assert!(store.edit_segment(run, segment, "").is_err());
    store.assign_segment(run, segment, None).unwrap();
    assert!(store.transcript(meeting).unwrap()["segments"][0]["person_name"].is_null());
}

#[test]
fn local_transcription_and_diarization_start_concurrently() {
    use std::os::unix::fs::PermissionsExt;
    let (tmp, store, meeting, mut config) = setup();
    let engine = tmp.path().join("parallel.py");
    std::fs::write(&engine, r#"#!/usr/bin/env python3
import json,sqlite3,sys,time
from pathlib import Path
args=sys.argv[1:]
base=Path(__file__).parent
speech='-m' in args
own=base/('speech-started' if speech else 'diarization-started')
other=base/('diarization-started' if speech else 'speech-started')
own.touch()
deadline=time.monotonic()+3
while not other.exists() and time.monotonic()<deadline:
    time.sleep(.01)
assert other.exists(), 'The other model must start before this model finishes'
if speech:
    with sqlite3.connect(base/'db') as db:
        stage, start = db.execute("SELECT stage,started_at FROM processing_jobs WHERE status='running'").fetchone()
    assert stage == 'transcribing_and_separating' and start > 0, (stage,start)
    out=Path(args[args.index('-of')+1]+'.json')
    data={'transcription':[{'text':'Проверка','offsets':{'from':0,'to':200}}]}
else:
    out=Path(args[3])
    data={'turns':[{'start_ms':0,'end_ms':200,'speaker':0}]}
out.write_text(json.dumps(data))
"#).unwrap();
    std::fs::set_permissions(&engine, std::fs::Permissions::from_mode(0o755)).unwrap();
    config.engine = engine.clone();
    config.diarization = Some(vtracker::diarization::DiarizationConfig {
        engine,
        segmentation: config.model.clone(),
        embedding: config.model.clone(),
        speakers: 0,
        cluster_threshold: None,
    });
    store.enqueue(meeting).unwrap();
    store.run_next(&config).unwrap();
    let jobs = store.jobs().unwrap();
    assert_eq!(jobs[0]["stage"], "saving");
    assert!(jobs[0]["finished_at"].as_i64().unwrap() >= jobs[0]["started_at"].as_i64().unwrap());
    let transcript = store.transcript(meeting).unwrap();
    assert_eq!(transcript["parameters"]["parallel_diarization"], true);
    assert_eq!(transcript["segments"][0]["text"], "Проверка");
    assert_eq!(transcript["speaker_turns"].as_array().unwrap().len(), 1);
}
