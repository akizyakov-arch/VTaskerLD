//! Durable ingestion of finalized WAV fragments, independent of inference.
use crate::Store;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

impl Store {
    /// Copy before indexing. A crash after publication leaves a recoverable WAV.
    /// The audio root must be an application-owned directory, not a shared upload area.
    pub fn import_wav(&self, meeting: i64, source: &Path, root: &Path) -> Result<Value> {
        self.import_wav_inner(meeting, source, root, true)
    }
    fn import_wav_inner(
        &self,
        meeting: i64,
        source: &Path,
        root: &Path,
        imported: bool,
    ) -> Result<Value> {
        let exists: bool = self.0.query_row(
            "SELECT EXISTS(SELECT 1 FROM meetings WHERE id=?1)",
            [meeting],
            |r| r.get(0),
        )?;
        if !exists {
            bail!("cannot attach audio to missing meeting");
        }
        let dir = root.join(meeting.to_string());
        fs::create_dir_all(&dir)?;
        // Reserve a staging filename without overwriting another import.
        let mut index = 0u64;
        let (temp, mut output) = loop {
            let path = dir.join(format!(".import-{}-{index}.part", std::process::id()));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => break (path, file),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => index += 1,
                Err(e) => return Err(e.into()),
            }
        };
        let result = (|| {
            let mut input = File::open(source)?;
            let mut hash = Sha256::new();
            let mut buffer = [0; 65536];
            loop {
                let n = input.read(&mut buffer)?;
                if n == 0 {
                    break;
                }
                hash.update(&buffer[..n]);
                output.write_all(&buffer[..n])?;
            }
            output.sync_all()?;
            let digest = format!("{:x}", hash.finalize());
            let metadata = inspect(&temp)?;
            let destination = dir.join(format!("{digest}.wav"));
            // Hard link atomically publishes a completed file, never replacing one.
            match fs::hard_link(&temp, &destination) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    if checksum(&destination)? != digest {
                        bail!("existing recording checksum mismatch");
                    }
                }
                Err(e) => return Err(e.into()),
            }
            File::open(&dir)?.sync_all()?;
            self.index_wav(meeting, &destination, &digest, metadata)?;
            if imported {
                self.index_import(meeting, &digest, "import")?;
            }
            Ok(json!({"sha256":digest,"path":fs::canonicalize(destination)?,"frames":metadata.2}))
        })();
        drop(output);
        let _ = fs::remove_file(temp);
        result
    }
    fn index_wav(
        &self,
        meeting: i64,
        path: &Path,
        digest: &str,
        meta: (u32, u16, u32),
    ) -> Result<()> {
        let path = fs::canonicalize(path)?;
        let path = path.to_str().context("recording path must be UTF-8")?;
        self.0.execute("INSERT INTO recordings(meeting_id,path,sha256,sample_rate,channels,frames) VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(meeting_id,sha256) DO NOTHING",rusqlite::params![meeting,path,digest,meta.0,meta.1,meta.2])?;
        Ok(())
    }
    /// Recover published fragments that were not indexed before an interruption.
    /// Incomplete .part files are preserved for diagnosis and never imported.
    pub fn recover_audio(&self, meeting: i64, root: &Path) -> Result<usize> {
        self.export(meeting)?;
        let dir = root.join(meeting.to_string());
        if !dir.exists() {
            return Ok(0);
        }
        let mut checked = 0;
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("wav") {
                continue;
            }
            let digest = checksum(&path)?;
            if path.file_stem().and_then(|s| s.to_str()) != Some(digest.as_str()) {
                bail!("recording checksum mismatch: {}", path.display());
            }
            self.index_wav(meeting, &path, &digest, inspect(&path)?)?;
            self.index_import(meeting, &digest, "recovered")?;
            checked += 1;
        }
        Ok(checked)
    }
    pub fn recordings(&self, meeting: i64) -> Result<Value> {
        let mut stmt = self.0.prepare("SELECT id,path,sha256,sample_rate,channels,frames FROM recordings WHERE meeting_id=?1 ORDER BY id")?;
        let rows = stmt.query_map([meeting], |r| Ok(json!({"id":r.get::<_,i64>(0)?,"path":r.get::<_,String>(1)?,"sha256":r.get::<_,String>(2)?,"sample_rate":r.get::<_,u32>(3)?,"channels":r.get::<_,u16>(4)?,"frames":r.get::<_,u32>(5)?})))?;
        Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
    }
}
pub(crate) fn checksum(path: &Path) -> Result<String> {
    let mut input = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn inspect(path: &Path) -> Result<(u32, u16, u32)> {
    let mut reader = hound::WavReader::open(path).context("invalid WAV fragment")?;
    let spec = reader.spec();
    let frames = reader.duration();
    if spec.channels == 0 || spec.sample_rate == 0 || frames == 0 {
        bail!("WAV must contain audio frames");
    }
    match spec.sample_format {
        hound::SampleFormat::Float => {
            for sample in reader.samples::<f32>() {
                if !sample?.is_finite() {
                    bail!("non-finite audio sample");
                }
            }
        }
        hound::SampleFormat::Int => {
            for sample in reader.samples::<i32>() {
                sample?;
            }
        }
    }
    Ok((spec.sample_rate, spec.channels, frames))
}

impl Store {
    /// Register an occurrence separately from its deduplicated content blob.
    pub fn import_fragment(
        &self,
        meeting: i64,
        session: &str,
        sequence: u32,
        source: &Path,
        root: &Path,
    ) -> Result<Value> {
        validate_session(meeting, session)?;
        let imported = self.import_wav_inner(meeting, source, root, false)?;
        let digest = imported["sha256"].as_str().context("missing checksum")?;
        let tx = self.0.unchecked_transaction()?;
        let (recording,rate,channels,frames): (i64,u32,u16,u32) = tx.query_row(
            "SELECT id,sample_rate,channels,frames FROM recordings WHERE meeting_id=?1 AND sha256=?2",
            rusqlite::params![meeting,digest],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
        let count: u32 = tx.query_row(
            "SELECT count(*) FROM capture_fragments WHERE session_id=?1",
            [session],
            |r| r.get(0),
        )?;
        if sequence < count {
            let existing: i64 = tx.query_row(
                "SELECT recording_id FROM capture_fragments WHERE session_id=?1 AND sequence=?2",
                rusqlite::params![session, sequence],
                |r| r.get(0),
            )?;
            if existing != recording {
                bail!("fragment changed after publication");
            }
        } else {
            if sequence != count {
                bail!("fragment sequence gap: expected {count}, got {sequence}");
            }
            let incompatible: u32 = tx.query_row("SELECT count(*) FROM capture_fragments f JOIN recordings r ON r.id=f.recording_id WHERE f.session_id=?1 AND (r.sample_rate!=?2 OR r.channels!=?3)",rusqlite::params![session,rate,channels],|r|r.get(0))?;
            if incompatible > 0 {
                bail!("audio format changed within capture session");
            }
            let start: i64 = tx.query_row("SELECT coalesce(sum(r.frames),0) FROM capture_fragments f JOIN recordings r ON r.id=f.recording_id WHERE f.session_id=?1",[session],|r|r.get(0))?;
            tx.execute("INSERT INTO capture_fragments(meeting_id,session_id,sequence,recording_id,start_frame) VALUES (?1,?2,?3,?4,?5)",rusqlite::params![meeting,session,sequence,recording,start])?;
        }
        tx.execute(
            "DELETE FROM audio_timeline WHERE recording_id=?1 AND kind='recovered'",
            [recording],
        )?;
        tx.execute("INSERT INTO audio_timeline(meeting_id,recording_id,session_id,sequence,kind) VALUES (?1,?2,?3,?4,'capture') ON CONFLICT(session_id,sequence) DO NOTHING", rusqlite::params![meeting,recording,session,sequence])?;
        tx.commit()?;
        Ok(
            json!({"session_id":session,"sequence":sequence,"recording_id":recording,"frames":frames,"sample_rate":rate,"sha256":digest}),
        )
    }
    pub fn fragments(&self, meeting: i64) -> Result<Value> {
        let mut stmt = self.0.prepare("SELECT f.session_id,f.sequence,f.recording_id,f.start_frame,r.frames,r.sample_rate,r.channels,s.source_json FROM capture_fragments f JOIN recordings r ON r.id=f.recording_id LEFT JOIN capture_sources s ON s.session_id=f.session_id WHERE f.meeting_id=?1 ORDER BY f.session_id,f.sequence")?;
        let rows = stmt.query_map([meeting],|r|Ok(json!({"session_id":r.get::<_,String>(0)?,"sequence":r.get::<_,u32>(1)?,"recording_id":r.get::<_,i64>(2)?,"start_frame":r.get::<_,i64>(3)?,"frames":r.get::<_,u32>(4)?,"sample_rate":r.get::<_,u32>(5)?,"channels":r.get::<_,u16>(6)?,"device":r.get::<_,Option<String>>(7)?.and_then(|s|serde_json::from_str::<Value>(&s).ok())})))?;
        Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
    }
    /// Run only after the capture owner has stopped. Retain staging fragments for replay.
    pub fn recover_capture(&self, meeting: i64, root: &Path) -> Result<usize> {
        if self.export(meeting)?["meeting"]["status"] == "recording" {
            bail!("stop capture or recover the interrupted meeting first");
        }
        let capture = root.join("capture");
        if !capture.exists() {
            return Ok(0);
        }
        let mut checked = 0;
        for entry in fs::read_dir(capture)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let session = entry.file_name();
            let Some(session) = session.to_str() else {
                continue;
            };
            if !session.starts_with(&format!("{meeting}-")) {
                continue;
            }
            validate_session(meeting, session)?;
            let source_path = entry.path().join("source.json");
            if source_path.is_file() {
                let source: Value = serde_json::from_reader(fs::File::open(source_path)?)?;
                self.register_capture_source(meeting, session, &source)?;
            }
            let mut files = Vec::new();
            for fragment in fs::read_dir(entry.path())? {
                let fragment = fragment?;
                let name = fragment.file_name();
                let Some(name) = name.to_str() else {
                    continue;
                };
                if name.len() == 10
                    && name.ends_with(".wav")
                    && name.as_bytes()[..6].iter().all(|b| b.is_ascii_digit())
                {
                    if !fragment.file_type()?.is_file() {
                        bail!("capture fragment must be a regular file");
                    }
                    files.push(fragment.path());
                }
            }
            files.sort();
            for path in files {
                let sequence: u32 = path.file_stem().unwrap().to_str().unwrap().parse()?;
                self.import_fragment(meeting, session, sequence, &path, root)?;
                checked += 1;
            }
        }
        Ok(checked)
    }
}
fn validate_session(meeting: i64, session: &str) -> Result<()> {
    let prefix = format!("{meeting}-");
    let suffix = session
        .strip_prefix(&prefix)
        .context("invalid capture session")?;
    if suffix.is_empty() || !suffix.bytes().all(|b| b.is_ascii_digit()) {
        bail!("invalid capture session");
    }
    Ok(())
}

impl Store {
    fn index_import(&self, meeting: i64, digest: &str, kind: &str) -> Result<()> {
        self.0.execute("INSERT INTO audio_timeline(meeting_id,recording_id,kind) SELECT meeting_id,id,?3 FROM recordings r WHERE meeting_id=?1 AND sha256=?2 AND NOT EXISTS(SELECT 1 FROM capture_fragments f WHERE f.recording_id=r.id) ON CONFLICT DO NOTHING", rusqlite::params![meeting,digest,kind])?;
        Ok(())
    }
    pub fn audio_inputs(&self, meeting: i64) -> Result<Vec<Value>> {
        let mut stmt=self.0.prepare("SELECT t.id,r.id,r.path,r.sha256,r.frames,r.sample_rate,t.session_id,t.sequence FROM audio_timeline t JOIN recordings r ON r.id=t.recording_id WHERE t.meeting_id=?1 ORDER BY t.id")?;
        let mut inputs:Vec<Value>=stmt.query_map([meeting], |r|Ok(json!({"occurrence_id":r.get::<_,i64>(0)?,"recording_id":r.get::<_,i64>(1)?,"path":r.get::<_,String>(2)?,"sha256":r.get::<_,String>(3)?,"frames":r.get::<_,u32>(4)?,"sample_rate":r.get::<_,u32>(5)?,"session_id":r.get::<_,Option<String>>(6)?,"sequence":r.get::<_,Option<u32>>(7)?})))?.collect::<rusqlite::Result<_>>()?;
        let mut ms = 0.0;
        for input in &mut inputs {
            input["start_ms"] = json!(ms as u64);
            ms += input["frames"].as_u64().unwrap() as f64 * 1000.0
                / input["sample_rate"].as_u64().unwrap() as f64;
            input["end_ms"] = json!(ms as u64);
        }
        Ok(inputs)
    }
}
