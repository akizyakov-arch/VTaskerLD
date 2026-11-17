//! Consent-backed, local voice sample enrollment. Embeddings are never returned by HTTP APIs.
use crate::{
    audio::checksum,
    speech::{resolve, run_command},
    Store,
};
use anyhow::{bail, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

pub struct VoiceConfig {
    pub engine: PathBuf,
    pub model: PathBuf,
    pub ffmpeg: PathBuf,
}
impl VoiceConfig {
    pub fn from_env() -> Result<Self> {
        let config = Self {
            engine: resolve(
                &std::env::var_os("VTRACKER_EMBED_BIN")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| {
                        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                            .join("native/diarization/.build/vtracker-embed")
                    }),
            )?,
            model: std::env::var_os("VTRACKER_EMBEDDING_MODEL")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    std::env::var_os("VTRACKER_TOOLS_DIR")
                        .map(PathBuf::from)
                        .unwrap_or_else(|| {
                            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                                .join(".local/share/vtracker")
                        })
                        .join("diarization/embedding.onnx")
                }),
            ffmpeg: resolve(
                &std::env::var_os("VTRACKER_FFMPEG_BIN")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| "ffmpeg".into()),
            )?,
        };
        if !config.model.is_file() {
            bail!("Не найдена модель голосовых профилей");
        }
        Ok(config)
    }
}
pub(crate) fn normalize(values: &[f64]) -> Result<Vec<f64>> {
    if values.is_empty() || values.len() > 4096 || values.iter().any(|v| !v.is_finite()) {
        bail!("Некорректный голосовой вектор");
    }
    let norm = values.iter().map(|v| v * v).sum::<f64>().sqrt();
    if !norm.is_finite() || norm < 1e-10 {
        bail!("Пустой голосовой вектор");
    }
    Ok(values.iter().map(|v| v / norm).collect())
}
pub(crate) fn quality(path: &Path) -> Result<Value> {
    let mut wav = hound::WavReader::open(path)?;
    let spec = wav.spec();
    if spec.channels != 1
        || spec.sample_rate != 16000
        || spec.bits_per_sample != 16
        || spec.sample_format != hound::SampleFormat::Int
    {
        bail!("Нужен mono PCM16 WAV 16 кГц");
    }
    let seconds = wav.duration() as f64 / 16000.0;
    if !(6.0..=60.0).contains(&seconds) {
        bail!("Образец должен содержать от 6 до 60 секунд речи одного человека");
    }
    let mut squares = 0.0;
    let mut clipped = 0usize;
    let mut audible = 0usize;
    let mut count = 0usize;
    for value in wav.samples::<i16>() {
        let v = value? as f64 / 32768.0;
        squares += v * v;
        clipped += usize::from(v.abs() > 0.99);
        audible += usize::from(v.abs() > 0.01);
        count += 1;
    }
    let rms = (squares / count as f64).sqrt();
    let clipping = clipped as f64 / count as f64;
    if rms < 0.003 || audible as f64 / (count as f64) < 0.02 {
        bail!("Образец слишком тихий или содержит мало звучащей речи. Запишите голос ближе к микрофону");
    }
    if clipping > 0.01 {
        bail!("В образце слишком много перегрузки сигнала. Уменьшите громкость микрофона");
    }
    Ok(
        json!({"duration_seconds":seconds,"rms":rms,"clipped_fraction":clipping,"audible_fraction":audible as f64/count as f64,"check":"technical-only-single-speaker-confirmed-by-user"}),
    )
}
const MAX_VOICE_SAMPLES: i64 = 3;

pub(crate) fn require_voice_sample_slot(db: &rusqlite::Connection, person: i64) -> Result<()> {
    let occupied: i64 = db.query_row(
        "SELECT (SELECT COUNT(*) FROM voice_samples WHERE person_id=?1)
              + (SELECT COUNT(*) FROM voice_jobs WHERE person_id=?1 AND state IN ('pending','running'))",
        [person], |row| row.get(0),
    )?;
    if occupied >= MAX_VOICE_SAMPLES {
        bail!("На участника можно сохранить до {MAX_VOICE_SAMPLES} голосовых образцов, включая образцы в обработке");
    }
    Ok(())
}

impl Store {
    pub fn queue_voice_sample(
        &self,
        person: i64,
        source: &Path,
        root: &Path,
        consent: bool,
        single_speaker: bool,
    ) -> Result<i64> {
        if !consent || !single_speaker {
            bail!("Нужны согласие участника на голосовой профиль и подтверждение, что в образце говорит только он");
        }
        let real: bool = self
            .0
            .query_row("SELECT is_demo=0 FROM people WHERE id=?1", [person], |r| {
                r.get(0)
            })
            .context("Участник не найден")?;
        if !real {
            bail!("Голосовые профили недоступны для демонстрационных участников");
        }
        if std::fs::metadata(source)?.len() > 16 * 1024 * 1024 {
            bail!("Голосовой образец должен быть не больше 16 МБ");
        }
        std::fs::create_dir_all(root)?;
        let root = std::fs::canonicalize(root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
        }
        let tx = self.0.unchecked_transaction()?;
        require_voice_sample_slot(&tx, person)?;
        tx.execute(
            "INSERT INTO voice_consents(person_id) VALUES (?1)",
            [person],
        )?;
        let consent_id = tx.last_insert_rowid();
        tx.execute(
            "INSERT INTO voice_jobs(person_id,consent_id,input_path) VALUES (?1,?2,'')",
            params![person, consent_id],
        )?;
        let job = tx.last_insert_rowid();
        let destination = root.join(format!("pending-{job}.input"));
        let result = (|| -> Result<()> {
            use std::io::Write;
            let mut input = std::fs::File::open(source)?;
            let mut output = std::fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&destination)?;
            std::io::copy(&mut input, &mut output)?;
            output.flush()?;
            output.sync_all()?;
            tx.execute(
                "UPDATE voice_jobs SET input_path=?2 WHERE id=?1",
                params![job, destination.to_string_lossy()],
            )?;
            Ok(())
        })();
        if let Err(error) = result {
            let _ = std::fs::remove_file(destination);
            return Err(error);
        }
        if let Err(error) = tx.commit() {
            let _ = std::fs::remove_file(destination);
            return Err(error.into());
        }
        Ok(job)
    }
    pub fn voice_snapshot(&self) -> Result<Value> {
        let mut stmt=self.0.prepare("SELECT p.id,p.person_id,p.model_sha256,p.revision,p.sample_count,p.created_at FROM voice_profiles p WHERE p.revision=(SELECT max(q.revision) FROM voice_profiles q WHERE q.person_id=p.person_id AND q.model_sha256=p.model_sha256) ORDER BY p.person_id,p.id")?;
        let profiles:Vec<Value>=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"person_id":r.get::<_,i64>(1)?,"model_sha256":r.get::<_,String>(2)?,"revision":r.get::<_,i64>(3)?,"sample_count":r.get::<_,i64>(4)?,"created_at":r.get::<_,String>(5)?})))?.collect::<rusqlite::Result<_>>()?;
        let mut stmt = self.0.prepare(
            "SELECT id,person_id,state,error,created_at FROM voice_jobs ORDER BY id DESC LIMIT 50",
        )?;
        let jobs:Vec<Value>=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"person_id":r.get::<_,i64>(1)?,"state":r.get::<_,String>(2)?,"error":r.get::<_,Option<String>>(3)?,"created_at":r.get::<_,String>(4)?})))?.collect::<rusqlite::Result<_>>()?;
        let mut stmt=self.0.prepare("SELECT j.id,j.model_run_id,m.meeting_id,j.state,j.error,j.created_at FROM voice_match_jobs j JOIN model_runs m ON m.id=j.model_run_id ORDER BY j.id DESC LIMIT 50")?;
        let match_jobs:Vec<Value>=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,i64>(0)?,"model_run_id":r.get::<_,i64>(1)?,"meeting_id":r.get::<_,i64>(2)?,"state":r.get::<_,String>(3)?,"error":r.get::<_,Option<String>>(4)?,"created_at":r.get::<_,String>(5)?})))?.collect::<rusqlite::Result<_>>()?;
        Ok(
            json!({"profiles":profiles,"sample_limit":MAX_VOICE_SAMPLES,"jobs":jobs,"match_jobs":match_jobs,"settings":self.voice_matching_settings()?}),
        )
    }
    pub fn voice_busy(&self) -> Result<bool> {
        Ok(self.0.query_row(
            "SELECT EXISTS(SELECT 1 FROM voice_jobs WHERE state='running') OR EXISTS(SELECT 1 FROM voice_match_jobs WHERE state='running')",
            [],
            |r| r.get(0),
        )?)
    }
    pub fn run_voice_job(
        &self,
        id: i64,
        root: &Path,
        scratch: &Path,
        config: &VoiceConfig,
    ) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        let busy:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM meetings WHERE status='recording') OR EXISTS(SELECT 1 FROM processing_jobs WHERE status='running') OR EXISTS(SELECT 1 FROM live_chunks WHERE state='running') OR EXISTS(SELECT 1 FROM voice_jobs WHERE state='running') OR EXISTS(SELECT 1 FROM voice_match_jobs WHERE state='running')",[],|r|r.get(0))?;
        if busy {
            bail!("Голосовой профиль ожидает окончания записи и другой обработки");
        }
        let (person,consent,input,source):(i64,i64,String,Option<String>)=tx.query_row("SELECT j.person_id,j.consent_id,j.input_path,j.source_json FROM voice_jobs j JOIN voice_consents c ON c.id=j.consent_id WHERE j.id=?1 AND j.state='pending' AND c.revoked_at IS NULL",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
        tx.execute(
            "UPDATE voice_jobs SET state='running',error=NULL WHERE id=?1",
            [id],
        )?;
        tx.commit()?;
        let wav = scratch.join("sample.wav");
        let published = root.join(format!("sample-{id}.wav"));
        let outcome = (|| -> Result<()> {
            if let Some(source) = &source {
                self.prepare_voice_excerpt(
                    &serde_json::from_str::<Value>(source)?,
                    &wav,
                    scratch,
                    config,
                )?;
            } else {
                run_command(
                    Command::new(&config.ffmpeg)
                        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
                        .arg(&input)
                        .args([
                            "-ac",
                            "1",
                            "-ar",
                            "16000",
                            "-c:a",
                            "pcm_s16le",
                            "-threads",
                            "1",
                            "-t",
                            "61",
                        ])
                        .arg(&wav),
                    Duration::from_secs(20),
                )?;
            }
            let quality = quality(&wav)?;
            let output = scratch.join("embedding.json");
            run_command(
                Command::new(&config.engine)
                    .arg(&config.model)
                    .arg(&wav)
                    .arg(&output),
                Duration::from_secs(30),
            )?;
            let result: Value = serde_json::from_reader(std::fs::File::open(output)?)?;
            let values: Vec<f64> = result["embedding"]
                .as_array()
                .context("Отсутствует голосовой вектор")?
                .iter()
                .map(|v| v.as_f64().context("Некорректный голосовой вектор"))
                .collect::<Result<_>>()?;
            let embedding = normalize(&values)?;
            let model_hash = checksum(&config.model)?;
            let engine_hash = checksum(&config.engine)?;
            std::fs::create_dir_all(root)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
            }
            let tx = self.0.unchecked_transaction()?;
            let active: bool = tx.query_row(
                "SELECT revoked_at IS NULL FROM voice_consents WHERE id=?1",
                [consent],
                |r| r.get(0),
            )?;
            if !active {
                bail!("Согласие на голосовой профиль отозвано");
            }
            let mut from = std::fs::File::open(&wav)?;
            let mut to = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&published)?;
            std::io::copy(&mut from, &mut to)?;
            to.sync_all()?;
            std::fs::File::open(&published)?.sync_all()?;
            std::fs::File::open(root)?.sync_all()?;
            tx.execute("INSERT INTO voice_samples(person_id,consent_id,job_id,path,sha256,model_sha256,engine_sha256,embedding_json,quality_json) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",params![person,consent,id,published.to_string_lossy(),checksum(&published)?,model_hash,engine_hash,json!(embedding).to_string(),quality.to_string()])?;
            let mut stmt=tx.prepare("SELECT embedding_json FROM voice_samples WHERE person_id=?1 AND model_sha256=?2 ORDER BY id")?;
            let rows: Vec<String> = stmt
                .query_map(params![person, model_hash], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            let mut mean = vec![0.0; embedding.len()];
            for row in &rows {
                let vector: Vec<f64> = serde_json::from_str(row)?;
                if vector.len() != mean.len() {
                    bail!("Размерность модели изменилась без смены версии");
                }
                for (m, v) in mean.iter_mut().zip(vector) {
                    *m += v;
                }
            }
            let mean = normalize(&mean)?;
            let revision:i64=tx.query_row("SELECT coalesce(max(revision),0)+1 FROM voice_profiles WHERE person_id=?1 AND model_sha256=?2",params![person,model_hash],|r|r.get(0))?;
            tx.execute("INSERT INTO voice_profiles(person_id,model_sha256,revision,sample_count,embedding_json) VALUES (?1,?2,?3,?4,?5)",params![person,model_hash,revision,rows.len() as i64,json!(mean).to_string()])?;
            tx.execute(
                "UPDATE voice_jobs SET state='completed',input_path='' WHERE id=?1",
                [id],
            )?;
            tx.commit()?;
            let _ = std::fs::remove_file(&input);
            Ok(())
        })();
        if let Err(error) = outcome {
            let _ = std::fs::remove_file(published);
            self.0.execute(
                "UPDATE voice_jobs SET state='failed',error=?2 WHERE id=?1",
                params![id, error.to_string()],
            )?;
            return Err(error);
        }
        Ok(())
    }
    pub fn delete_voice(&self, person: i64, root: &Path, confirmed: bool) -> Result<()> {
        if !confirmed {
            bail!("Подтвердите удаление образцов и голосовых профилей");
        }
        if self.voice_busy()? {
            bail!("Дождитесь окончания обработки голосового профиля");
        }
        let tx = self.0.unchecked_transaction()?;
        let mut stmt = tx.prepare("SELECT id FROM voice_jobs WHERE person_id=?1")?;
        let jobs: Vec<i64> = stmt
            .query_map([person], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        drop(stmt);
        for id in jobs {
            for name in [format!("sample-{id}.wav"), format!("pending-{id}.input")] {
                match std::fs::remove_file(root.join(name)) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e.into()),
                }
            }
        }
        tx.execute("DELETE FROM voice_matches WHERE person_id=?1", [person])?;
        tx.execute("DELETE FROM voice_profiles WHERE person_id=?1", [person])?;
        tx.execute("DELETE FROM voice_samples WHERE person_id=?1", [person])?;
        tx.execute("DELETE FROM voice_jobs WHERE person_id=?1", [person])?;
        tx.execute("UPDATE voice_consents SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE person_id=?1 AND revoked_at IS NULL",[person])?;
        tx.commit()?;
        Ok(())
    }
    pub fn retry_voice(&self, id: i64) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        let person: i64 = tx.query_row(
            "SELECT j.person_id FROM voice_jobs j JOIN voice_consents c ON c.id=j.consent_id
             WHERE j.id=?1 AND j.state='failed' AND c.revoked_at IS NULL",
            [id], |row| row.get(0),
        ).context("Задание не найдено, не завершилось ошибкой или согласие отозвано")?;
        require_voice_sample_slot(&tx, person)?;
        tx.execute("UPDATE voice_jobs SET state='pending',error=NULL WHERE id=?1", [id])?;
        tx.commit()?;
        Ok(())
    }
    pub fn recover_voice(&self, confirmed: bool) -> Result<()> {
        if !confirmed {
            bail!("Подтвердите остановку прежних процессов");
        }
        self.0.execute("UPDATE voice_jobs SET state='failed',error='Голосовая обработка прервана; восстановлена оператором' WHERE state='running'",[])?;
        self.0.execute("UPDATE voice_match_jobs SET state='failed',error='Сопоставление голосов прервано; восстановлено оператором' WHERE state='running'",[])?;
        Ok(())
    }
}
#[derive(Default)]
pub struct VoiceWorker {
    child: Option<Child>,
    scratch: Option<tempfile::TempDir>,
    job: Option<i64>,
    kind: Option<String>,
    started: Option<Instant>,
}
impl VoiceWorker {
    pub fn busy(&self) -> bool {
        self.child.is_some()
    }
    pub fn status(&self) -> Value {
        let config = VoiceConfig::from_env();
        json!({"running":self.busy(),"job_id":self.job,"kind":self.kind,"configured":config.is_ok(),"configuration_error":config.err().map(|e|e.to_string())})
    }
    pub fn poll(&mut self, db: &Path, store: &Store, can_start: bool) -> Result<()> {
        if let Some(child) = self.child.as_mut() {
            if self
                .started
                .is_some_and(|t| t.elapsed() > Duration::from_secs(65))
            {
                crate::live::kill_group(child);
            }
            if let Some(exit) = child.try_wait()? {
                if !exit.success() {
                    if let Some(id) = self.job {
                        let table = if self.kind.as_deref() == Some("match") {
                            "voice_match_jobs"
                        } else {
                            "voice_jobs"
                        };
                        store.0.execute(&format!("UPDATE {table} SET state='failed',error=coalesce(error,'Голосовой обработчик завершился с ошибкой или превысил время ожидания') WHERE id=?1 AND state IN ('pending','running')"),[id])?;
                    }
                }
                self.child = None;
                self.scratch = None;
                self.job = None;
                self.kind = None;
                self.started = None;
            }
        }
        if !can_start || self.busy() || VoiceConfig::from_env().is_err() || store.voice_busy()? {
            return Ok(());
        }
        let next:Option<(i64,String)>=store.0.query_row("SELECT id,kind FROM (SELECT id,'enroll' AS kind,0 AS priority FROM voice_jobs WHERE state='pending' UNION ALL SELECT id,'match' AS kind,1 AS priority FROM voice_match_jobs WHERE state='pending') ORDER BY priority,id LIMIT 1",[],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((id, kind)) = next {
            let scratch = tempfile::Builder::new().prefix("vtask-voice-").tempdir()?;
            let mut command = Command::new("/usr/bin/nice");
            command
                .args(["-n", "10"])
                .arg(std::env::current_exe()?)
                .arg("--db")
                .arg(db)
                .arg(if kind == "match" {
                    "voice-match-run"
                } else {
                    "voice-run"
                })
                .arg(id.to_string())
                .arg("--scratch")
                .arg(scratch.path());
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
            self.job = Some(id);
            self.kind = Some(kind);
            self.started = Some(Instant::now());
            self.scratch = Some(scratch);
        }
        Ok(())
    }
}
impl Drop for VoiceWorker {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            crate::live::kill_group(child);
        }
    }
}
