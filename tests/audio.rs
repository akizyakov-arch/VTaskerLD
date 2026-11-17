use vtracker::Store;
fn wav(path: &std::path::Path) {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 16000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    for i in 0..1600 {
        writer.write_sample((i % 100) as i16).unwrap();
    }
    writer.finalize().unwrap();
}
#[test]
fn import_is_durable_idempotent_and_recoverable() {
    let tmp = tempfile::tempdir().unwrap();
    let db = tmp.path().join("db.sqlite3");
    let store = Store::open(&db).unwrap();
    let id = store.create_meeting("Audio").unwrap();
    let source = tmp.path().join("input.wav");
    wav(&source);
    let root = tmp.path().join("audio");
    let imported = store.import_wav(id, &source, &root).unwrap();
    assert_eq!(imported["frames"], 1600);
    store.import_wav(id, &source, &root).unwrap();
    assert_eq!(store.recordings(id).unwrap().as_array().unwrap().len(), 1);
    std::fs::remove_file(source).unwrap();
    assert!(std::path::Path::new(imported["path"].as_str().unwrap()).exists());
    // Simulate the crash window after publishing WAV but before SQLite registration.
    let conn = rusqlite::Connection::open(db).unwrap();
    conn.execute("DELETE FROM recordings", []).unwrap();
    std::fs::write(
        root.join(id.to_string()).join("unfinished.part"),
        b"partial",
    )
    .unwrap();
    assert_eq!(store.recover_audio(id, &root).unwrap(), 1);
    assert_eq!(store.recover_audio(id, &root).unwrap(), 1);
    assert_eq!(
        store.export(id).unwrap()["recordings"][0]["sample_rate"],
        16000
    );
    std::fs::write(imported["path"].as_str().unwrap(), b"corrupted").unwrap();
    assert!(store.recover_audio(id, &root).is_err());
}
#[test]
fn invalid_input_leaves_no_recording() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let id = store.create_meeting("Audio").unwrap();
    let source = tmp.path().join("bad.wav");
    std::fs::write(&source, b"not audio").unwrap();
    let root = tmp.path().join("audio");
    assert!(store.import_wav(id, &source, &root).is_err());
    assert_eq!(
        std::fs::read_dir(root.join(id.to_string()))
            .unwrap()
            .count(),
        0
    );
    assert!(store.import_wav(999, &source, &root).is_err());
}
#[test]
fn upgrades_existing_v1_database_without_losing_people() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("old.sqlite3");
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute_batch(include_str!("../migrations/001_initial.sql"))
        .unwrap();
    conn.pragma_update(None, "user_version", 1).unwrap();
    conn.execute("INSERT INTO people(name) VALUES ('Антон')", [])
        .unwrap();
    drop(conn);
    let store = Store::open(&path).unwrap();
    assert_eq!(store.people().unwrap()[0]["name"], "Антон");
    let id = store.create_meeting("Migrated").unwrap();
    assert_eq!(store.recordings(id).unwrap(), serde_json::json!([]));
}

#[test]
fn capture_recovery_replays_identical_fragments_without_losing_time() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let id = store.create_meeting("Recovered").unwrap();
    let root = tmp.path().join("audio");
    let session = format!("{id}-12345");
    let dir = root.join("capture").join(&session);
    std::fs::create_dir_all(&dir).unwrap();
    wav(&dir.join("000000.wav"));
    wav(&dir.join("000001.wav"));
    std::fs::write(dir.join("000002.partial.wav"), b"unfinished").unwrap();
    assert_eq!(store.recover_capture(id, &root).unwrap(), 2);
    assert_eq!(store.recover_capture(id, &root).unwrap(), 2);
    let fragments = store.fragments(id).unwrap();
    assert_eq!(fragments.as_array().unwrap().len(), 2);
    assert_eq!(fragments[1]["start_frame"], 1600);
    assert_eq!(fragments[1]["frames"], 1600);
    assert_eq!(fragments[0]["recording_id"], fragments[1]["recording_id"]);
    assert_eq!(store.recordings(id).unwrap().as_array().unwrap().len(), 1);
    assert!(store
        .import_fragment(id, "../escape", 2, &dir.join("000001.wav"), &root)
        .is_err());
}
#[test]
fn capture_recovery_reports_a_gap_and_keeps_preceding_audio() {
    let tmp = tempfile::tempdir().unwrap();
    let store = Store::open(&tmp.path().join("db")).unwrap();
    let id = store.create_meeting("Gap").unwrap();
    let root = tmp.path().join("audio");
    let dir = root.join("capture").join(format!("{id}-123"));
    std::fs::create_dir_all(&dir).unwrap();
    wav(&dir.join("000000.wav"));
    wav(&dir.join("000002.wav"));
    assert!(store.recover_capture(id, &root).is_err());
    assert_eq!(store.fragments(id).unwrap().as_array().unwrap().len(), 1);
}
