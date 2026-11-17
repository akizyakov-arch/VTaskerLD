use vtracker::Store;
#[test]
fn persistence_export_and_queue_constraints() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("nested/test.sqlite3");
    let id;
    {
        let store = Store::open(&path).unwrap();
        store.add_person("Антон").unwrap();
        assert!(store.add_person("  ").is_err());
        id = store.create_meeting("Планирование").unwrap();
        let job = store.enqueue(id).unwrap();
        assert!(store.enqueue(id).is_err());
        assert!(store.enqueue(999).is_err());
        assert!(store.retry(job).is_err());
        assert!(store.export(999).is_err());
    }
    let store = Store::open(&path).unwrap();
    assert_eq!(store.people().unwrap()[0]["name"], "Антон");
    assert_eq!(
        store.export(id).unwrap()["meeting"]["title"],
        "Планирование"
    );
    assert!(store.export(id).unwrap()["transcript"].is_null());
    assert_eq!(store.jobs().unwrap()[0]["status"], "pending");
}
#[test]
fn retry_failed_job_preserves_attempt_count() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("test.sqlite3");
    let store = Store::open(&path).unwrap();
    let id = store.create_meeting("Test").unwrap();
    let job = store.enqueue(id).unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute("UPDATE processing_jobs SET status='failed',attempts=2,error='model unavailable' WHERE id=?1", [job]).unwrap();
    store.retry(job).unwrap();
    let jobs = store.jobs().unwrap();
    assert_eq!(jobs[0]["status"], "pending");
    assert_eq!(jobs[0]["attempts"], 2);
    assert!(jobs[0]["error"].is_null());
}
