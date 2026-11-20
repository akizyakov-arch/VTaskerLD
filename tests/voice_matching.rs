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
fn live_voice_hint_reaches_the_final_transcript_until_its_consent_is_revoked() {
    let (tmp,store,person,run,_config,voice) = setup();
    enroll(&tmp,&store,person,&voice);
    let c = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    let meeting: i64 = c.query_row("SELECT meeting_id FROM model_runs WHERE id=?1",[run],|row| row.get(0)).unwrap();
    c.execute("INSERT INTO meeting_people(meeting_id,person_id) VALUES (?1,?2)",[meeting,person]).unwrap();
    c.execute("INSERT INTO live_voice_hints(occurrence_id,meeting_id,profile_id,person_id,start_ms,end_ms,similarity)
         SELECT a.id,a.meeting_id,v.id,v.person_id,0,20000,0.9 FROM audio_timeline a
         JOIN voice_profiles v ON v.person_id=?2 WHERE a.meeting_id=?1",[meeting,person]).unwrap();
    let transcript = store.transcript(meeting).unwrap();
    let segment = &transcript["segments"][0];
    assert!(segment["person_id"].is_null());
    assert_eq!(segment["voice_suggestion"]["person_id"],person);
    assert_eq!(segment["voice_suggestion"]["source"],"live_voice");
    let other = store.add_person("Manual override").unwrap();
    c.execute(
        "INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id)
         SELECT model_run_id,start_ms,end_ms,'speaker_1' FROM speaker_turns
         WHERE model_run_id=?1 AND speaker_id='speaker_0'",
        [run],
    )
    .unwrap();
    let split = store.transcript(meeting).unwrap();
    assert_eq!(split["segments"][0]["speaker_status"], "multiple");
    assert_eq!(split["segments"][0]["voice_suggestion"]["person_id"], person);
    assert_eq!(split["segments"][0]["voice_suggestion"]["source"], "segment_consensus");
    store.assign_speaker(run, "speaker_1", Some(other)).unwrap();
    assert!(store.transcript(meeting).unwrap()["segments"][0]["voice_suggestion"].is_null());
    store.assign_segment(run,segment["id"].as_i64().unwrap(),Some(other)).unwrap();
    let manual = store.transcript(meeting).unwrap();
    assert_eq!(manual["segments"][0]["person_id"],other);
    assert!(manual["segments"][0]["voice_suggestion"].is_null());
    c.execute("DELETE FROM segment_assignments WHERE model_run_id=?1 AND segment_id=?2",
        [run,segment["id"].as_i64().unwrap()]).unwrap();
    c.execute("DELETE FROM speaker_assignments WHERE model_run_id=?1 AND speaker_id='speaker_1'", [run]).unwrap();
    assert_eq!(store.transcript(meeting).unwrap()["segments"][0]["voice_suggestion"]["person_id"], person);
    c.execute("UPDATE voice_consents SET revoked_at='2026-11-18' WHERE person_id=?1",[person]).unwrap();
    assert!(store.transcript(meeting).unwrap()["segments"][0]["voice_suggestion"].is_null());
}
#[test]
fn meeting_enrollment_excludes_overlap_and_records_consent_provenance() {
    let (tmp, store, person, run, config, voice) = setup();
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

    let next = store.create_meeting("Следующее совещание").unwrap();
    c.execute(
        "INSERT INTO meeting_people(meeting_id,person_id) VALUES (?1,?2)",
        [next, person],
    )
    .unwrap();
    store.import_wav(next, &tmp.path().join("speech.wav"), &tmp.path().join("audio")).unwrap();
    store.enqueue(next).unwrap();
    store.run_next(&config).unwrap();
    let next_run = store.transcript(next).unwrap()["model_run_id"].as_i64().unwrap();
    let match_job = store.latest_voice_match_job(next_run).unwrap().unwrap();
    assert_eq!(match_job["state"], "pending");
    store
        .run_voice_matching(
            match_job["id"].as_i64().unwrap(),
            tempfile::tempdir().unwrap().path(),
            &voice,
        )
        .unwrap();
    assert_eq!(store.transcript(next).unwrap()["segments"][0]["person_id"], person);
    assert_eq!(
        hound::WavReader::open(tmp.path().join("voice").join(format!("sample-{job}.wav")))
            .unwrap()
            .duration(),
        224000
    );
}
#[test]
fn meeting_voice_limit_is_shared_across_meetings_and_independent_of_manual_samples() {
    let (tmp, store, person, first_run, config, voice) = setup();
    let voice_root = tmp.path().join("voice");
    for _ in 0..3 {
        enroll(&tmp, &store, person, &voice);
    }

    let mut runs = vec![first_run];
    for _ in 0..3 {
        let meeting = store.create_meeting("Another meeting").unwrap();
        store
            .import_wav(meeting, &tmp.path().join("speech.wav"), &tmp.path().join("audio"))
            .unwrap();
        store.enqueue(meeting).unwrap();
        store.run_next(&config).unwrap();
        runs.push(store.transcript(meeting).unwrap()["model_run_id"].as_i64().unwrap());
    }
    let queue = |run| store.queue_voice_from_meeting(person, run, "speaker_0", true, true);

    for (index, &run) in runs[..3].iter().enumerate() {
        let job = queue(run).unwrap();
        assert_eq!(queue(run).unwrap(), job);
        let status = store.voice_snapshot().unwrap();
        assert_eq!(status["sample_usage"][0]["meeting_ms"], index * 20_000);
        assert_eq!(status["sample_usage"][0]["pending_meeting_ms"], 20_000);
        if index == 2 {
            let error = queue(runs[3]).unwrap_err();
            assert!(error.to_string().contains("60 секунд"));
            let db = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
            db.execute("UPDATE voice_jobs SET state='failed' WHERE id=?1", [job]).unwrap();
            store.retry_voice(job).unwrap();
        }
        store
            .run_voice_job(job, &voice_root, tempfile::tempdir().unwrap().path(), &voice)
            .unwrap();
    }

    assert!(queue(runs[3]).unwrap_err().to_string().contains("60 секунд"));
    let status = store.voice_snapshot().unwrap();
    assert_eq!(status["meeting_sample_limit_ms"], 60_000);
    assert_eq!(status["profiles"][0]["sample_count"], 6);
    assert_eq!(status["sample_usage"][0], json!({
        "person_id": person, "manual_samples": 3, "pending_manual_samples": 0,
        "meeting_ms": 60_000, "pending_meeting_ms": 0
    }));
    for id in 1..=3 {
        assert!(voice_root.join(format!("sample-{id}.wav")).is_file());
    }

    let other = store.add_person("Another participant").unwrap();
    let job = store.queue_voice_from_meeting(other, first_run, "speaker_0", true, true).unwrap();
    store
        .run_voice_job(job, &voice_root, tempfile::tempdir().unwrap().path(), &voice)
        .unwrap();
    for _ in 0..3 {
        enroll(&tmp, &store, other, &voice);
    }
    assert!(store.queue_voice_sample(other, &tmp.path().join("speech.wav"), &voice_root, true, true)
        .unwrap_err().to_string().contains("до 3"));
}

#[test]
fn selected_fragments_assign_atomically_and_save_one_sample_without_counting_overlap_twice() {
    let (tmp, store, person, run, _config, voice) = setup();
    let conn = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    conn.execute("UPDATE segments SET end_ms=6000 WHERE model_run_id=?1", [run]).unwrap();
    let first = store.transcript(1).unwrap()["segments"][0]["id"].as_i64().unwrap();
    conn.execute(
        "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,5000,10000,'Вторая реплика','[]')",
        [run],
    ).unwrap();
    let second = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,10000,20000,'Остальная реплика','[]')",
        [run],
    ).unwrap();
    let previous = matches(&store, run, &voice);
    assert_eq!(previous[0]["status"], "unknown");
    let consent = json!({"consent":true,"single_speaker":true});
    assert!(store.assign_voice_fragments(run, &[first, -1], person, true, None).is_err());
    assert!(store.transcript(1).unwrap()["segments"][0]["person_id"].is_null());
    assert!(store.assign_voice_fragments(run, &[first, second], person, true, Some(&json!({"consent":false,"single_speaker":true}))).is_err());
    assert!(store.transcript(1).unwrap()["segments"][0]["person_id"].is_null());
    let saved = store.assign_voice_fragments(run, &[first, second], person, false, Some(&consent)).unwrap();
    assert_eq!(saved["assigned"], 0);
    assert!(store.transcript(1).unwrap()["segments"][0]["person_id"].is_null());
    let result = store.assign_voice_fragments(run, &[first, second, first], person, true, Some(&consent)).unwrap();
    assert_eq!(result["assigned"], 2);
    assert_eq!(result["job_id"], saved["job_id"]);
    let repeated = store.assign_voice_fragments(run, &[second, first], person, true, Some(&consent)).unwrap();
    assert_eq!(repeated["job_id"], result["job_id"]);
    assert_eq!(store.voice_snapshot().unwrap()["jobs"].as_array().unwrap().len(), 1);
    assert_eq!(conn.query_row("SELECT count(*) FROM segment_assignments", [], |row| row.get::<_, i64>(0)).unwrap(), 2);
    let transcript = store.transcript(1).unwrap();
    assert!(transcript["segments"].as_array().unwrap()[..2].iter().all(|s| s["person_id"] == person));
    assert!(transcript["segments"][2]["person_id"].is_null());
    let job = result["job_id"].as_i64().unwrap();
    store.run_voice_job(job, &tmp.path().join("voice"), tempfile::tempdir().unwrap().path(), &voice).unwrap();
    let audio = tmp.path().join("voice").join(format!("sample-{job}.wav"));
    assert_eq!(hound::WavReader::open(audio).unwrap().duration(), 160_000);
    assert_eq!(store.voice_snapshot().unwrap()["profiles"][0]["sample_count"], 1);
    let rematch = store.latest_voice_match_job(run).unwrap().unwrap();
    assert_eq!(rematch["state"], "pending");
    store.run_voice_matching(rematch["id"].as_i64().unwrap(), tempfile::tempdir().unwrap().path(), &voice).unwrap();
    let refreshed = store.transcript(1).unwrap();
    assert_eq!(refreshed["model_run_id"], run);
    assert_eq!(refreshed["segments"][0]["assignment_source"], "manual_segment");
    assert_eq!(refreshed["segments"][2]["person_id"], person);
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
    let preview = store.voice_source_preview(run, "speaker_0").unwrap();
    assert_eq!(preview["duration_ms"], 5000);
    assert_eq!(preview["minimum_enrollment_ms"], 6000);
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
fn strong_match_assigns_a_voice_and_manual_assignments_take_priority() {
    let (tmp, store, person, run, _config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    let results = matches(&store, run, &voice);
    assert_eq!(results[0]["status"], "candidate");
    assert_eq!(results[0]["person_id"], person);
    assert!(results[0]["similarity"].as_f64().unwrap() > 0.999);
    let transcript = store.transcript(1).unwrap();
    assert_eq!(transcript["segments"][0]["person_id"], person);
    assert_eq!(
        transcript["segments"][0]["assignment_source"],
        "auto_profile"
    );
    assert!(transcript["segments"][0]["voice_suggestion"].is_null());
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
    let segment = transcript["segments"][0]["id"].as_i64().unwrap();
    let other = store.add_person("Другой участник").unwrap();
    store.assign_segment(run, segment, Some(other)).unwrap();
    assert!(store.assign_speaker_from_segment(run, "speaker_0", Some(person), Some(-1)).is_err());
    assert_eq!(store.speaker_assignments(run, true).unwrap().len(), 2);
    store.assign_speaker_from_segment(run, "speaker_0", Some(person), Some(segment)).unwrap();
    let corrected = store.transcript(1).unwrap();
    assert_eq!(corrected["segments"][0]["person_id"], person);
    assert_eq!(corrected["segments"][0]["assignment_source"], "manual_segment");
}

#[test]
fn final_diarization_uses_the_selected_participant_count() {
    let (tmp, store, person, _run, mut config, _voice) = setup();
    let second = store.add_person("Второй участник").unwrap();
    let db = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    for participant in [person, second] {
        db.execute("INSERT INTO meeting_people(meeting_id,person_id) VALUES(1,?1)",[participant]).unwrap();
    }
    config.diarization.as_mut().unwrap().speakers = 0;
    store.enqueue(1).unwrap();
    store.run_next(&config).unwrap();
    let t = store.transcript(1).unwrap();
    assert_eq!(t["parameters"]["diarization"]["num_speakers"], 2);
    assert_eq!(t["parameters"]["diarization"]["speaker_count_source"], "meeting_participants");
    assert_eq!(t["speaker_turns"].as_array().unwrap().len(), 2);
}

#[test]
fn short_interruptions_keep_the_main_profile_but_balanced_voices_stay_separate() {
    let (tmp, store, person, run, _config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    matches(&store, run, &voice);
    let db = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    db.execute("INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id) VALUES (?1,2000,4000,'speaker_1')",
        [run]).unwrap();
    let t = store.transcript(1).unwrap();
    assert_eq!(t["segments"][0]["person_id"], person);
    assert!(t["segments"][0]["overlap_label"].is_string());
    db.execute("UPDATE speaker_turns SET end_ms=17000 WHERE model_run_id=?1 AND speaker_id='speaker_1'", [run]).unwrap();
    assert!(store.transcript(1).unwrap()["segments"][0]["person_id"].is_null());
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
fn overlapping_replicas_display_both_known_speakers() {
    let (tmp, store, person, run, _config, _voice) = setup();
    let db = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    db.execute("INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id) VALUES (?1,2000,7000,'speaker_1')",
        [run]).unwrap();
    store.assign_speaker(run, "speaker_0", Some(person)).unwrap();
    assert_eq!(store.transcript(1).unwrap()["segments"][0]["overlap_label"],
        "Registered participant и неопознанный голос · одновременно");
    let other = store.add_person("Даша").unwrap();
    store.assign_speaker(run, "speaker_1", Some(other)).unwrap();
    let t = store.transcript(1).unwrap();
    assert_eq!(t["segments"][0]["overlap_label"], "Registered participant и Даша · одновременно");
    assert!(t["segments"][0]["person_id"].is_null());
}

#[test]
fn consistent_manual_labels_assign_other_replicas_in_the_same_group() {
    let (tmp, store, person, run, _config, _voice) = setup();
    let conn = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    conn.execute("UPDATE segments SET end_ms=4000 WHERE model_run_id=?1", [run]).unwrap();
    for (start, end) in [(4_000, 8_000), (8_000, 20_000)] {
        conn.execute(
            "INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,?2,?3,'Реплика','[]')",
            rusqlite::params![run, start, end],
        ).unwrap();
    }
    let transcript = store.transcript(1).unwrap();
    let first = transcript["segments"][0]["id"].as_i64().unwrap();
    let second = transcript["segments"][1]["id"].as_i64().unwrap();
    let third = transcript["segments"][2]["id"].as_i64().unwrap();
    store.assign_segment(run, first, Some(person)).unwrap();
    store.assign_segment(run, first, Some(person)).unwrap();
    assert!(store.transcript(1).unwrap()["segments"][2]["person_id"].is_null());
    store.assign_segment(run, second, Some(person)).unwrap();
    let updated = store.transcript(1).unwrap();
    assert_eq!(updated["segments"][2]["person_id"], person);
    assert_eq!(updated["segments"][2]["assignment_source"], "auto_reviewed_group");
    store.assign_segment(run, third, None).unwrap();
    assert!(store.transcript(1).unwrap()["segments"][2]["person_id"].is_null());
    let other = store.add_person("Другой говорящий").unwrap();
    store.assign_segment(run, second, Some(other)).unwrap();
    let groups = store.transcript(1).unwrap();
    assert_eq!(groups["segments"][0]["person_id"], person);
    assert_eq!(groups["segments"][1]["person_id"], other);
    conn.execute("DELETE FROM segment_assignments WHERE model_run_id=?1 AND segment_id=?2",
        rusqlite::params![run, third]).unwrap();
    assert!(store.transcript(1).unwrap()["segments"][2]["person_id"].is_null());
}

#[test]
fn voice_matching_checks_every_group_in_a_long_run() {
    let (tmp, store, person, run, _config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    let db = rusqlite::Connection::open(tmp.path().join("db")).unwrap();
    for number in 1..=18 {
        db.execute("INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id) VALUES (?1,0,1000,?2)",
                   rusqlite::params![run, format!("speaker_{number}")]).unwrap();
    }
    let results = matches(&store, run, &voice);
    let results = results.as_array().unwrap();
    assert_eq!(results.len(), 19);
    assert!(results.iter().filter(|row| row["speaker_id"] != "speaker_0").all(|row|
        row["reason"].as_str().unwrap().contains("Недостаточно чистой речи")));
}

#[test]
fn automatic_matching_respects_settings_and_reuses_one_job_per_transcript() {
    let (tmp, store, person, run, config, voice) = setup();
    enroll(&tmp, &store, person, &voice);
    assert!(store.voice_snapshot().unwrap()["match_jobs"]
        .as_array()
        .unwrap()
        .is_empty());
    let automatic = store.ensure_automatic_voice_matching(run).unwrap().unwrap();
    assert_eq!(automatic["state"], "pending");
    assert_eq!(store.ensure_automatic_voice_matching(run).unwrap().unwrap(), automatic);
    assert_eq!(store.queue_voice_matching(run).unwrap(), automatic["id"].as_i64().unwrap());
    store
        .save_voice_matching_settings(&json!({"enabled":false,"threshold":0.75,"margin":0.1}))
        .unwrap();
    store.enqueue(1).unwrap();
    store.run_next(&config).unwrap();
    let disabled_run = store.transcript(1).unwrap()["model_run_id"].as_i64().unwrap();
    assert!(store.ensure_automatic_voice_matching(disabled_run).unwrap().is_none());
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
