//! Preliminary local transcription of durable capture fragments. Final model_runs stay independent.
use crate::{
    audio::checksum,
    speech::{parse_segments, run_command, SpeechConfig},
    Store,
};
use anyhow::{bail, Result};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::Path,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

mod blocks;

pub const QUEUE_LIMIT: i64 = 4;
impl Store {
    pub fn start_live(
        &self,
        meeting: i64,
        session: &str,
        model: &Path,
        language: &str,
    ) -> Result<()> {
        let valid: bool = self.0.query_row(
            "SELECT status='recording' AND is_demo=0 FROM meetings WHERE id=?1",
            [meeting],
            |r| r.get(0),
        )?;
        if !valid || !session.starts_with(&format!("{meeting}-")) {
            bail!("Live требует активной записи реальной встречи");
        }
        self.0.execute("INSERT INTO live_sessions(session_id,meeting_id,state,model_path,language) VALUES (?1,?2,'active',?3,?4)", params![session,meeting,model.to_string_lossy(),language])?;
        Ok(())
    }
    /// Queue references only, never audio buffers. A growing backlog switches to Post-Meeting.
    pub fn queue_live(&self, session: &str) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        let active: bool = tx
            .query_row(
                "SELECT state='active' FROM live_sessions WHERE session_id=?1",
                [session],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(false);
        if !active {
            return Ok(());
        }
        let outstanding: i64 = tx.query_row(
            "SELECT count(*) FROM live_chunks WHERE state IN ('pending','running')",
            [],
            |r| r.get(0),
        )?;
        let mut stmt = tx.prepare("SELECT f.sequence,f.recording_id,CAST(coalesce((SELECT sum(r2.frames*1000.0/r2.sample_rate) FROM audio_timeline t2 JOIN recordings r2 ON r2.id=t2.recording_id WHERE t2.meeting_id=f.meeting_id AND t2.id<t.id),0) AS INTEGER),r.frames,r.sample_rate FROM capture_fragments f JOIN recordings r ON r.id=f.recording_id JOIN audio_timeline t ON t.session_id=f.session_id AND t.sequence=f.sequence WHERE f.session_id=?1 AND NOT EXISTS (SELECT 1 FROM live_chunks c WHERE c.session_id=f.session_id AND c.sequence=f.sequence) ORDER BY f.sequence LIMIT 5")?;
        let rows: Vec<(i64, i64, i64, i64, i64)> = stmt
            .query_map([session], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
            })?
            .collect::<rusqlite::Result<_>>()?;
        drop(stmt);
        if outstanding + rows.len() as i64 > QUEUE_LIMIT {
            tx.execute("UPDATE live_sessions SET state='deferred',reason='Live не успевает за записью: обработка отложена до завершения встречи' WHERE session_id=?1", [session])?;
            tx.execute(
                "UPDATE live_chunks SET state='deferred' WHERE session_id=?1 AND state='pending'",
                [session],
            )?;
        } else {
            for (sequence, recording, start, frames, rate) in rows {
                tx.execute("INSERT INTO live_chunks(session_id,sequence,recording_id,start_ms,end_ms) VALUES (?1,?2,?3,?4,?5)",params![session,sequence,recording,start,start+frames*1000/rate])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
    pub fn defer_live(&self, session: &str, reason: &str) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        tx.execute("UPDATE live_sessions SET state='deferred',reason=?2 WHERE session_id=?1 AND state='active'", params![session,reason])?;
        tx.execute(
            "UPDATE live_chunks SET state='deferred' WHERE session_id=?1 AND state='pending'",
            [session],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn finish_live(&self, session: &str) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        tx.execute(
            "UPDATE live_sessions SET state='finished' WHERE session_id=?1 AND state='active'",
            [session],
        )?;
        tx.execute(
            "UPDATE live_chunks SET state='deferred' WHERE session_id=?1 AND state='pending'",
            [session],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn live_busy(&self) -> Result<bool> {
        Ok(self.0.query_row(
            "SELECT EXISTS(SELECT 1 FROM live_chunks WHERE state='running')",
            [],
            |r| r.get(0),
        )?)
    }
    /// Operator recovery only, after all old Live processes are confirmed stopped.
    pub fn recover_live(&self, meeting: i64) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        tx.execute("UPDATE live_chunks SET state='failed',error='Live прерван; выполнено восстановление оператором' WHERE session_id IN (SELECT session_id FROM live_sessions WHERE meeting_id=?1) AND state IN ('running','pending')",[meeting])?;
        tx.execute("UPDATE live_sessions SET state='interrupted',reason='Live прерван; доступна обработка сохранённого аудио' WHERE meeting_id=?1 AND state IN ('active','deferred')",[meeting])?;
        tx.commit()?;
        Ok(())
    }
    pub fn live_snapshot(&self, meeting: i64) -> Result<Value> {
        let session: Option<(String,String,Option<String>,String)> = self.0.query_row("SELECT session_id,state,reason,model_path FROM live_sessions WHERE meeting_id=?1 ORDER BY rowid DESC LIMIT 1",[meeting],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        let Some((session, state, reason, model)) = session else {
            return Ok(Value::Null);
        };
        let mut stmt=self.0.prepare("SELECT id,sequence,state,result_json,start_ms,end_ms,elapsed_ms,error,model_sha256,engine_sha256,last_sequence FROM live_chunks WHERE session_id=?1 ORDER BY sequence")?;
        let chunks: Vec<Value>=stmt.query_map([&session],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"sequence":r.get::<_,i64>(1)?,"state":r.get::<_,String>(2)?,"segments":serde_json::from_str::<Value>(&r.get::<_,String>(3)?).unwrap_or(json!([])),"start_ms":r.get::<_,i64>(4)?,"end_ms":r.get::<_,i64>(5)?,"elapsed_ms":r.get::<_,Option<i64>>(6)?,"error":r.get::<_,Option<String>>(7)?,"model_sha256":r.get::<_,Option<String>>(8)?,"engine_sha256":r.get::<_,Option<String>>(9)?,"last_sequence":r.get::<_,Option<i64>>(10)?})))?.collect::<rusqlite::Result<_>>()?;
        let raw: String = self.0.query_row(
            "SELECT speaker_turns_json FROM live_sessions WHERE session_id=?1",
            [&session], |row| row.get(0),
        )?;
        let turns: Vec<Value> = serde_json::from_str(&raw)?;
        let mut chunks = chunks;
        if !turns.is_empty() {
            let mut next_turn = 0;
            let mut active_turns = Vec::<Value>::new();
            for segment in chunks.iter_mut().filter_map(|chunk| chunk["segments"].as_array_mut()).flatten() {
                if let (Some(start), Some(end)) = (segment["start_ms"].as_u64(), segment["end_ms"].as_u64()) {
                    active_turns.retain(|turn| turn["end_ms"].as_u64().unwrap_or(0) > start);
                    while let Some(turn) = turns.get(next_turn)
                        .filter(|turn| turn["start_ms"].as_u64().is_some_and(|time| time < end))
                    {
                        if turn["end_ms"].as_u64().unwrap_or(0) > start {
                            active_turns.push(turn.clone());
                        }
                        next_turn += 1;
                    }
                    segment["speaker_id"] = crate::diarization::attribution(start, end, &active_turns)["speaker_id"].clone();
                }
            }
        }
        Ok(
            json!({"session_id":session,"state":state,"reason":reason,"model":model,"status":"preliminary","chunks":chunks}),
        )
    }
    pub fn run_live_chunk(&self, id: i64, mut config: SpeechConfig, scratch: &Path) -> Result<()> {
        // All expensive work is performed by this background process, never by the capture owner.
        config.diarization = None;
        config.validate()?;
        let tx = self.0.unchecked_transaction()?;
        let busy: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM live_chunks WHERE state='running') OR EXISTS(SELECT 1 FROM processing_jobs WHERE status='running')",[],|r|r.get(0))?;
        if busy || self.voice_busy()? {
            bail!("Другой обработчик уже использует модель");
        }
        let (session,start,end,path,hash,model,language,sequence):(String,u64,u64,String,String,String,String,i64)=tx.query_row("SELECT c.session_id,c.start_ms,c.end_ms,r.path,r.sha256,s.model_path,s.language,c.sequence FROM live_chunks c JOIN recordings r ON r.id=c.recording_id JOIN live_sessions s ON s.session_id=c.session_id WHERE c.id=?1 AND c.state='pending' AND s.state='active'",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?)))?;
        tx.execute("UPDATE live_chunks SET state='running' WHERE id=?1", [id])?;
        tx.commit()?;
        let began = Instant::now();
        let outcome = (|| -> Result<()> {
            config.model = model.into();
            config.language = language;
            config.validate()?;
            let model_hash = checksum(&config.model)?;
            let engine_hash = checksum(&config.engine)?;
            if checksum(Path::new(&path))? != hash {
                bail!("Повреждён сохранённый WAV-фрагмент");
            }
            let wav = scratch.join("input.wav");
            let prefix = scratch.join("result");
            config.normalize_audio(Path::new(&path), &wav, Duration::from_secs(10))?;
            let mut command = Command::new(&config.engine);
            command
                .arg("-m")
                .arg(&config.model)
                .arg("-f")
                .arg(&wav)
                .arg("-l")
                .arg(&config.language)
                .args(["-t", "2", "-bo", "1", "-bs", "1", "-nf", "-oj", "-of"])
                .arg(&prefix);
            config.configure_vad(&mut command);
            run_command(&mut command, Duration::from_secs(20))?;
            let output: Value =
                serde_json::from_reader(std::fs::File::open(prefix.with_extension("json"))?)?;
            let duration = hound::WavReader::open(&wav)?.duration() as u64 * 1000 / 16000;
            let recording: i64 = self.0.query_row(
                "SELECT recording_id FROM live_chunks WHERE id=?1",
                [id],
                |r| r.get(0),
            )?;
            let source = json!({"recording_id":recording,"session_id":session,"sequence":sequence,"path":path,"sha256":hash,"start_ms":0,"end_ms":duration});
            let mut segments = parse_segments(&output, duration, &[source])?;
            for segment in &mut segments {
                segment["start_ms"] = json!(start + segment["start_ms"].as_u64().unwrap());
                segment["end_ms"] = json!((start + segment["end_ms"].as_u64().unwrap()).min(end));
                segment["status"] = json!("preliminary");
                for source in segment["sources"].as_array_mut().unwrap() {
                    source["start_ms"] = json!(start);
                    source["end_ms"] = json!(end);
                }
            }
            self.0.execute("UPDATE live_chunks SET state='completed',result_json=?2,model_sha256=?3,elapsed_ms=?4,engine_sha256=?5 WHERE id=?1 AND state='running'",params![id,json!(segments).to_string(),model_hash,began.elapsed().as_millis() as i64,engine_hash])?;
            Ok(())
        })();
        match outcome {
            Ok(()) => {
                // Two slow chunks are enough to yield resources back to recording.
                let slow:i64=self.0.query_row("SELECT count(*) FROM (SELECT elapsed_ms,end_ms-start_ms AS duration FROM live_chunks WHERE session_id=?1 AND state='completed' ORDER BY sequence DESC LIMIT 2) WHERE elapsed_ms > max(1000,duration*3/2)",[&session],|r|r.get(0))?;
                if slow == 2 {
                    self.defer_live(&session,"Live работает медленнее записи: распознавание отложено до завершения встречи")?;
                }
                Ok(())
            }
            Err(error) => {
                self.0.execute(
                    "UPDATE live_chunks SET state='failed',error=?2,elapsed_ms=?3 WHERE id=?1",
                    params![id, error.to_string(), began.elapsed().as_millis() as i64],
                )?;
                self.defer_live(&session,"Ошибка Live-распознавания. Запись продолжается; сохранённое аудио можно обработать после встречи")?;
                Err(error)
            }
        }
    }
}

#[derive(Default)]
pub struct LiveWorker {
    child: Option<Child>,
    scratch: Option<tempfile::TempDir>,
    started: Option<Instant>,
    chunk: Option<i64>,
    block_mode: bool,
    pub session: Option<String>,
    pub last_error: Option<String>,
}
impl LiveWorker {
    pub fn busy(&self) -> bool {
        self.child.is_some()
    }
    pub fn status(&self) -> Value {
        json!({"running":self.busy(),"chunk_id":self.chunk,"session_id":self.session,"error":self.last_error})
    }
    pub fn attach(&mut self, session: String) {
        self.block_mode = crate::speech::blocks::engine().is_some();
        self.session = Some(session);
        self.last_error = None;
    }
    pub fn poll(&mut self, db: &Path, store: &Store, capturing: bool) -> Result<()> {
        if self.block_mode {
            return self.poll_blocks(db, store, capturing);
        }
        if let Some(child) = self.child.as_mut() {
            if self
                .started
                .is_some_and(|t| t.elapsed() > Duration::from_secs(35))
            {
                kill_group(child);
                self.last_error = Some("Live превысил лимит времени; запись продолжается".into());
            }
            if let Some(exit) = child.try_wait()? {
                if !exit.success() {
                    if let Some(id) = self.chunk {
                        store.0.execute("UPDATE live_chunks SET state='failed',error=coalesce(error,'Live-процесс завершился с ошибкой') WHERE id=?1 AND state IN ('pending','running')",[id])?;
                    }
                    if let Some(session) = &self.session {
                        store.defer_live(
                            session,
                            "Live остановлен из-за ошибки; запись продолжается",
                        )?;
                    }
                }
                self.child = None;
                self.scratch = None;
                self.started = None;
                self.chunk = None;
            }
        }
        let Some(session) = &self.session else {
            return Ok(());
        };
        if !capturing {
            store.finish_live(session)?;
            return Ok(());
        }
        store.queue_live(session)?;
        if self.busy() {
            return Ok(());
        }
        let next:Option<(i64,String)>=store.0.query_row("SELECT c.id,s.model_path FROM live_chunks c JOIN live_sessions s ON s.session_id=c.session_id WHERE c.session_id=?1 AND c.state='pending' AND s.state='active' ORDER BY c.sequence LIMIT 1",[session],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((id, model)) = next {
            let scratch = tempfile::Builder::new().prefix("vtask-live-").tempdir()?;
            let mut command = Command::new("/usr/bin/nice");
            command
                .args(["-n", "10"])
                .arg(std::env::current_exe()?)
                .arg("--db")
                .arg(db)
                .arg("live-chunk")
                .arg(id.to_string())
                .arg("--scratch")
                .arg(scratch.path())
                .env("VTRACKER_WHISPER_MODEL", model)
                .env_remove("VTRACKER_CLOUD_URL")
                .env_remove("VTRACKER_CLOUD_KEY");
            #[cfg(unix)]
            {
                use std::os::unix::process::CommandExt;
                command.process_group(0);
            }
            self.child = Some(
                command
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()?,
            );
            self.scratch = Some(scratch);
            self.started = Some(Instant::now());
            self.chunk = Some(id);
        }
        Ok(())
    }
    fn poll_blocks(&mut self, db: &Path, store: &Store, capturing: bool) -> Result<()> {
        let Some(session) = self.session.as_deref() else { return Ok(()); };
        if let Some(child) = self.child.as_mut() {
            if !capturing {
                if let Some(scratch) = &self.scratch {
                    let finish = scratch.path().join("finish");
                    if !finish.exists() { std::fs::write(finish, [])?; }
                }
            }
            if let Some(exit) = child.try_wait()? {
                self.child = None;
                self.scratch = None;
                if !exit.success() {
                    self.last_error = Some("Live-обработка завершилась с ошибкой".into());
                    store.0.execute(
                        "UPDATE live_chunks SET state='failed',error=?2 WHERE session_id=?1 AND state='running'",
                        params![session,self.last_error],
                    )?;
                    store.defer_live(session, "Live остановлен. Сохранённое аудио доступно для обработки")?;
                }
                self.session = None;
            }
            return Ok(());
        }
        if !capturing {
            store.finish_live(session)?;
            self.session = None;
            return Ok(());
        }
        let scratch = tempfile::Builder::new().prefix("vtask-live-blocks-").tempdir()?;
        let mut command = Command::new("/usr/bin/nice");
        command.args(["-n", "10"]).arg(std::env::current_exe()?)
            .arg("--db").arg(db).arg("live-blocks").arg(session)
            .arg("--scratch").arg(scratch.path())
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        self.child = Some(command.spawn()?);
        self.scratch = Some(scratch);
        Ok(())
    }

}
pub(crate) fn kill_group(child: &mut Child) {
    #[cfg(unix)]
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.kill();
    let _ = child.wait();
}
impl Drop for LiveWorker {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            kill_group(child);
        }
    }
}
