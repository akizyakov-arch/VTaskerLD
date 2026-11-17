use rusqlite::Connection;
use std::path::Path;
use vtracker::Store;

fn schema(path: &Path) -> Vec<(String, String)> {
    let connection = Connection::open(path).unwrap();
    let mut statement = connection
        .prepare("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY name")
        .unwrap();
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
}

#[test]
fn every_historical_version_upgrades_to_the_same_schema_and_preserves_people() {
    let directory = tempfile::tempdir().unwrap();
    let fresh = directory.path().join("fresh.sqlite3");
    drop(Store::open(&fresh).unwrap());
    let expected = schema(&fresh);
    let mut scripts: Vec<_> =
        std::fs::read_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "sql"))
            .collect();
    scripts.sort();

    for version in 0..=scripts.len() {
        let path = directory.path().join(format!("v{version}.sqlite3"));
        let connection = Connection::open(&path).unwrap();
        for script in scripts.iter().take(version) {
            connection
                .execute_batch(&std::fs::read_to_string(script).unwrap())
                .unwrap();
        }
        connection
            .pragma_update(None, "user_version", version)
            .unwrap();
        if version > 0 {
            connection
                .execute(
                    "INSERT INTO people(name) VALUES ('Сохранённый участник')",
                    [],
                )
                .unwrap();
        }
        drop(connection);

        drop(Store::open(&path).unwrap());
        assert_eq!(schema(&path), expected, "schema from version {version}");
        if version > 0 {
            let connection = Connection::open(&path).unwrap();
            let name: String = connection
                .query_row("SELECT name FROM people WHERE id=1", [], |row| row.get(0))
                .unwrap();
            assert_eq!(name, "Сохранённый участник");
        }
    }
}

#[test]
fn unsupported_version_is_rejected_without_changing_schema_version() {
    let directory = tempfile::tempdir().unwrap();
    for version in [-1, 999] {
        let path = directory
            .path()
            .join(format!("unsupported-{version}.sqlite3"));
        let connection = Connection::open(&path).unwrap();
        connection
            .pragma_update(None, "user_version", version)
            .unwrap();
        drop(connection);
        assert!(Store::open(&path).is_err());
        let connection = Connection::open(&path).unwrap();
        let preserved: i64 = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(preserved, version);
    }
}
