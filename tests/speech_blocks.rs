#![cfg(unix)]

use rusqlite::Connection;
use std::{os::unix::fs::PermissionsExt, path::Path, process::Command};
use vtracker::Store;

#[test]
fn live_blocks_are_reused_by_final_processing_and_keep_speaker_labels() {
    let scratch = tempfile::tempdir().unwrap();
    let db = scratch.path().join("db");
    let store = Store::open(&db).unwrap();
    let meeting = store.create_meeting("Block processing").unwrap();
    let session = format!("{meeting}-123");
    let wav = scratch.path().join("fragment.wav");
    for sequence in 0..27 {
        let mut writer = hound::WavWriter::create(
            &wav,
            hound::WavSpec {
                channels: 1,
                sample_rate: 16000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .unwrap();
        for _ in 0..80_000 {
            writer.write_sample(sequence as i16).unwrap();
        }
        writer.finalize().unwrap();
        store
            .import_fragment(
                meeting,
                &session,
                sequence,
                &wav,
                &scratch.path().join("audio"),
            )
            .unwrap();
    }

    let engine = scratch.path().join("model-worker.py");
    std::fs::write(
        &engine,
        r#"#!/usr/bin/env python3
import json,sys,pathlib,time,wave
root=pathlib.Path(__file__).parent
for line in sys.stdin:
    request=json.loads(line)
    if (root/'check-parallel').exists():
        current,other=('whisper','speaker') if 'pcm' in request else ('speaker','whisper')
        (root/current).touch()
        deadline=time.monotonic()+5
        while not (root/other).exists():
            if time.monotonic()>deadline:
                raise RuntimeError('inference workers did not overlap')
            time.sleep(0.01)
    if 'pcm' in request:
        path=pathlib.Path(request['pcm'])
        duration=path.stat().st_size//64
        result={'transcription':[{'text':'Речь','offsets':{'from':0,'to':duration}}]}
    else:
        (root/'speaker-threads').write_text(sys.argv[4])
        path=pathlib.Path(request['wav'])
        with wave.open(str(path),'rb') as audio:
            duration=audio.getnframes()//16
        result={'turns':[{'start_ms':0,'end_ms':duration,'speaker':0}],'voices':{'0':[1.,0.]}}
    with (pathlib.Path(__file__).parent/'calls').open('a') as log:
        log.write(next(iter(request))+'\n')
    print(json.dumps(result),flush=True)
"#,
    )
    .unwrap();
    std::fs::set_permissions(&engine, std::fs::Permissions::from_mode(0o755)).unwrap();
    let connection = Connection::open(&db).unwrap();
    connection
        .execute(
            "UPDATE meetings SET status='recording' WHERE id=?1",
            [meeting],
        )
        .unwrap();
    store.start_live(meeting, &session, &engine, "ru").unwrap();
    std::fs::write(scratch.path().join("finish"), []).unwrap();

    let command = |args: &[&str]| {
        let result = Command::new(env!("CARGO_BIN_EXE_vtracker"))
            .arg("--db")
            .arg(&db)
            .args(args)
            .env("VTRACKER_WHISPER_BIN", &engine)
            .env("VTRACKER_WHISPER_WORKER", &engine)
            .env("VTRACKER_WHISPER_MODEL", &engine)
            .env("VTRACKER_SPEAKER_WORKER", &engine)
            .env("VTRACKER_DIARIZATION_BIN", &engine)
            .env("VTRACKER_SEGMENTATION_MODEL", &engine)
            .env("VTRACKER_EMBEDDING_MODEL", &engine)
            .env(
                "VTRACKER_FFMPEG_BIN",
                vtracker::speech::resolve(Path::new("ffmpeg")).unwrap(),
            )
            .env_remove("VTRACKER_VAD_MODEL")
            .env_remove("VTRACKER_SPEAKERS")
            .env_remove("VTRACKER_CLOUD_URL")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    };
    command(&[
        "live-blocks",
        &session,
        "--scratch",
        scratch.path().to_str().unwrap(),
    ]);
    let preview = store.live_snapshot(meeting).unwrap();
    let chunks = preview["chunks"].as_array().unwrap();
    assert_eq!(chunks.len(), 5);
    assert_eq!(chunks[0]["last_sequence"], 5);
    assert_eq!(chunks[4]["segments"][0]["start_ms"], 120_000);
    assert_eq!(chunks[4]["segments"][0]["speaker_id"], "speaker_0");
    let calls = std::fs::read_to_string(scratch.path().join("calls")).unwrap();
    assert_eq!(calls.lines().filter(|line| *line == "pcm").count(), 5);
    assert_eq!(calls.lines().filter(|line| *line == "wav").count(), 2);
    assert_eq!(std::fs::read_to_string(scratch.path().join("speaker-threads")).unwrap(), "2");

    connection
        .execute(
            "UPDATE meetings SET status='completed' WHERE id=?1",
            [meeting],
        )
        .unwrap();
    store.enqueue(meeting).unwrap();
    command(&["jobs", "run", "--meeting", &meeting.to_string()]);
    let final_text = store.transcript(meeting).unwrap();
    assert_eq!(final_text["segments"].as_array().unwrap().len(), 5);
    assert_eq!(final_text["segments"][4]["speaker_id"], "speaker_0");
    assert_eq!(final_text["segments"][4]["end_ms"], 135_000);
    assert_eq!(final_text["parameters"]["audio_duration_ms"], 135_000);
    assert_eq!(final_text["parameters"]["cached_speech_blocks"], 5);
    assert_eq!(final_text["parameters"]["processed_speech_blocks"], 0);
    assert_eq!(
        std::fs::read_to_string(scratch.path().join("calls")).unwrap(),
        calls
    );

    connection.execute_batch("DELETE FROM speech_blocks; DELETE FROM speaker_blocks;").unwrap();
    std::fs::write(scratch.path().join("check-parallel"), []).unwrap();
    store.enqueue(meeting).unwrap();
    command(&["jobs", "run", "--meeting", &meeting.to_string()]);
    let parallel = store.transcript(meeting).unwrap();
    assert_eq!(parallel["parameters"]["parallel_diarization"], true);
    assert_eq!(parallel["parameters"]["cached_speech_blocks"], 0);
    assert_eq!(parallel["parameters"]["processed_speech_blocks"], 5);
    let expected_threads = std::thread::available_parallelism().map_or(2, |count| count.get().min(4));
    assert_eq!(parallel["parameters"]["diarization"]["threads"], expected_threads);
    assert_eq!(std::fs::read_to_string(scratch.path().join("speaker-threads")).unwrap(), expected_threads.to_string());
    assert_eq!(parallel["segments"][4]["speaker_id"], "speaker_0");
}
