//! A single recording owner per server. Control messages never invoke speech models.
use crate::Store;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

enum CaptureEvent {
    Ready,
    Device(Value),
    Capabilities,
    Level(f64),
    Error(String),
}
struct Session {
    _microphone_lock: std::fs::File,
    child: Child,
    source: Value,
    meeting: i64,
    directory: PathBuf,
    session_id: String,
    fragments: u32,
    error: Option<String>,
    ingest_failed: bool,
    pause_supported: bool,
    events: Receiver<CaptureEvent>,
    ready_at: Option<Instant>,
    paused_at: Option<Instant>,
    pause_total: Duration,
    level: Option<f64>,
    saved_frames: u64,
    base_ms: u64,
    sample_rate: u64,
    confirmed: bool,
    started: Instant,
    stopping: Option<Instant>,
    limit: Duration,
}
pub struct CaptureManager {
    helper: PathBuf,
    root: PathBuf,
    active: Option<Session>,
    last: Value,
}
impl CaptureManager {
    pub fn new(helper: PathBuf, root: PathBuf) -> Self {
        Self {
            helper,
            root,
            active: None,
            last: Value::Null,
        }
    }
    pub fn status(&self) -> Value {
        json!({"available":self.helper.is_file(),"active":self.active.as_ref().map(|s| {
            let pause=s.paused_at.map_or(Duration::ZERO,|t|t.elapsed());
            let elapsed=s.ready_at.map_or(Duration::ZERO,|t|t.elapsed()).saturating_sub(s.pause_total+pause);
            let elapsed_ms = elapsed.as_millis() as u64;
            let position_ms = s.base_ms.saturating_add(elapsed_ms);
            json!({"meeting_id":s.meeting,"session_id":s.session_id,"fragments":s.fragments,"saved_ms":s.base_ms+s.saved_frames*1000/s.sample_rate.max(1),"elapsed_ms":elapsed_ms,"position_ms":position_ms,"source":s.source["name"].as_str().unwrap_or("Микрофон по умолчанию"),"device":s.source,"level":s.level,"can_pause":s.pause_supported,"error":s.error,"state":if s.stopping.is_some(){"stopping"}else if s.paused_at.is_some(){"paused"}else if s.confirmed{"recording"}else{"starting"}})
        }),"last":self.last})
    }
    pub fn pause(&mut self, meeting: i64, resume: bool) -> Result<()> {
        let s = self.active.as_mut().context("Нет активной записи")?;
        if !s.pause_supported {
            bail!("Пауза требует обновления адаптера микрофона: swift build --package-path native/macos");
        }
        if s.meeting != meeting || !s.confirmed || s.stopping.is_some() {
            bail!("Запись ещё не готова или уже останавливается");
        }
        if resume {
            let paused = s.paused_at.context("Запись не на паузе")?;
            s.child
                .stdin
                .as_mut()
                .context("Нет связи с микрофоном")?
                .write_all(b"resume\n")?;
            s.pause_total += paused.elapsed();
            s.paused_at = None;
        } else {
            if s.paused_at.is_some() {
                bail!("Запись уже на паузе");
            }
            s.child
                .stdin
                .as_mut()
                .context("Нет связи с микрофоном")?
                .write_all(b"pause\n")?;
            s.paused_at = Some(Instant::now());
            s.level = Some(0.0);
        }
        Ok(())
    }
    pub fn start(&mut self, store: &Store, meeting: i64, seconds: u64) -> Result<()> {
        self.start_device(store, meeting, seconds, "")
    }
    pub fn start_device(
        &mut self,
        store: &Store,
        meeting: i64,
        seconds: u64,
        device: &str,
    ) -> Result<()> {
        self.start_inner(store, meeting, seconds, device, false)
    }
    pub fn continue_device(
        &mut self,
        store: &Store,
        meeting: i64,
        seconds: u64,
        device: &str,
    ) -> Result<()> {
        self.start_inner(store, meeting, seconds, device, true)
    }
    fn start_inner(
        &mut self,
        store: &Store,
        meeting: i64,
        seconds: u64,
        device: &str,
        continuation: bool,
    ) -> Result<()> {
        if self.active.is_some() {
            bail!("another recording is active");
        }
        if !(1..=7200).contains(&seconds) {
            bail!("duration must be 1..7200 seconds");
        }
        if !self.helper.is_file() {
            bail!("capture helper not found; build native/macos on a Mac first");
        }
        let base_ms = store
            .audio_inputs(meeting)?
            .last()
            .and_then(|v| v["end_ms"].as_u64())
            .unwrap_or(0);
        let microphone_lock = microphone_lock(&self.root)?;
        store.begin_capture(meeting, continuation)?;
        let result = (|| {
            let staging = self.root.join("capture");
            std::fs::create_dir_all(&staging)?;
            let staging = std::fs::canonicalize(staging)?;
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos();
            let session_id = format!("{meeting}-{stamp}");
            let directory = staging.join(&session_id);
            std::fs::create_dir(&directory)?;
            let mut command = Command::new(&self.helper);
            command.arg(&directory).arg(seconds.to_string());
            if !device.is_empty() {
                command.arg(device);
            }
            let mut child = command
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
                .context("cannot start microphone helper")?;
            let stdout = child.stdout.take().context("missing capture stdout")?;
            let (sender, events) = mpsc::sync_channel(64);
            std::thread::spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    match line {
                        Ok(line) if line.starts_with("DEVICE\t") => {
                            if let Ok(value) = serde_json::from_str::<Value>(&line[7..]) {
                                let _ = sender.send(CaptureEvent::Device(value));
                            }
                        }
                        Ok(line) if line == "READY" => {
                            let _ = sender.try_send(CaptureEvent::Ready);
                            // Continue draining stdout until the helper exits.
                        }
                        Ok(line) if line == "CAPABILITIES\tpause,level" => {
                            let _ = sender.try_send(CaptureEvent::Capabilities);
                        }
                        Ok(line) if line.starts_with("LEVEL\t") => {
                            if let Ok(value) = line[6..].parse::<f64>() {
                                if value.is_finite() {
                                    let _ =
                                        sender.try_send(CaptureEvent::Level(value.clamp(0.0, 1.0)));
                                }
                            }
                        }
                        Ok(line) if line.starts_with("ERROR\t") => {
                            let _ = sender
                                .send(CaptureEvent::Error(line[6..].chars().take(1500).collect()));
                        }
                        Ok(_) => {}
                        Err(_) => break,
                    }
                }
            });
            Ok(Session {
                _microphone_lock: microphone_lock,
                child,
                source: Value::Null,
                meeting,
                directory,
                session_id,
                fragments: 0,
                error: None,
                ingest_failed: false,
                pause_supported: false,
                events,
                ready_at: None,
                paused_at: None,
                pause_total: Duration::ZERO,
                level: None,
                saved_frames: 0,
                base_ms,
                sample_rate: 16000,
                confirmed: false,
                started: Instant::now(),
                stopping: None,
                limit: Duration::from_secs(seconds + 100),
            })
        })();
        match result {
            Ok(session) => {
                self.active = Some(session);
                self.last = Value::Null;
                Ok(())
            }
            Err(error) => {
                store.finish_capture(meeting, false)?;
                Err(error)
            }
        }
    }
    pub fn stop(&mut self, meeting: i64) -> Result<()> {
        let session = self.active.as_mut().context("no active recording")?;
        if session.meeting != meeting {
            bail!("this meeting is not being recorded");
        }
        if session.stopping.is_none() {
            session
                .child
                .stdin
                .as_mut()
                .context("capture input unavailable")?
                .write_all(b"stop\n")?;
            session.stopping = Some(Instant::now());
        }
        Ok(())
    }
    pub fn poll(&mut self, store: &Store) -> Result<()> {
        let Some(session) = self.active.as_mut() else {
            return Ok(());
        };
        // At most four small fragments per tick keeps the HTTP loop responsive.
        if !session.ingest_failed {
            for _ in 0..4 {
                let file = session
                    .directory
                    .join(format!("{:06}.wav", session.fragments));
                if !file.exists() {
                    break;
                }
                match store.import_fragment(
                    session.meeting,
                    &session.session_id,
                    session.fragments,
                    &file,
                    &self.root,
                ) {
                    Ok(fragment) => {
                        session.fragments += 1;
                        session.saved_frames += fragment["frames"].as_u64().unwrap_or(0);
                        session.sample_rate = fragment["sample_rate"].as_u64().unwrap_or(16000);
                    }
                    Err(error) => {
                        session.error = Some(error.to_string());
                        session.ingest_failed = true;
                        let _ = session.child.kill();
                        break;
                    }
                }
            }
        }
        for event in session.events.try_iter().take(128) {
            match event {
                CaptureEvent::Device(source) => {
                    store.register_capture_source(session.meeting, &session.session_id, &source)?;
                    session.source = source;
                }
                CaptureEvent::Ready => {
                    session.confirmed = true;
                    session.ready_at = Some(Instant::now());
                }
                CaptureEvent::Capabilities => session.pause_supported = true,
                CaptureEvent::Level(level) => session.level = Some(level),
                CaptureEvent::Error(error) => session.error = Some(error),
            }
        }
        let timed_out = session.started.elapsed() > session.limit
            || (!session.confirmed && session.started.elapsed() > Duration::from_secs(90))
            || session
                .stopping
                .is_some_and(|t| t.elapsed() > Duration::from_secs(10));
        if timed_out {
            let _ = session.child.kill();
        }
        if let Some(exit) = session.child.try_wait()? {
            // Keep polling if a completed fragment still needs indexing.
            if !session.ingest_failed
                && session
                    .directory
                    .join(format!("{:06}.wav", session.fragments))
                    .exists()
            {
                return Ok(());
            }
            // Drain the final protocol messages; the reader thread may run just after child exit.
            let protocol_deadline = Instant::now() + Duration::from_millis(20);
            while let Some(remaining) = protocol_deadline.checked_duration_since(Instant::now()) {
                match session.events.recv_timeout(remaining) {
                    Ok(CaptureEvent::Device(source)) => {
                        store.register_capture_source(
                            session.meeting,
                            &session.session_id,
                            &source,
                        )?;
                        session.source = source;
                    }
                    Ok(CaptureEvent::Ready) => session.confirmed = true,
                    Ok(CaptureEvent::Capabilities) => session.pause_supported = true,
                    Ok(CaptureEvent::Error(error)) => session.error = Some(error),
                    Ok(CaptureEvent::Level(level)) => session.level = Some(level),
                    Err(_) => break,
                }
            }
            // Exit 0 must not silently hide a gap or an unfinished final fragment.
            if session.error.is_none() {
                for entry in std::fs::read_dir(&session.directory)? {
                    let entry = entry?;
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    if name.ends_with(".partial.wav") {
                        session.error = Some("helper left an unfinished fragment".to_string());
                    } else if name.len() == 10
                        && name.ends_with(".wav")
                        && name.as_bytes()[..6].iter().all(u8::is_ascii_digit)
                    {
                        let sequence: u32 = name[..6].parse()?;
                        if sequence >= session.fragments {
                            session.error =
                                Some("helper left a gap in fragment sequence".to_string());
                        }
                    }
                }
            }
            let session = self.active.take().unwrap();
            let success = exit.success()
                && session.confirmed
                && session.fragments > 0
                && session.error.is_none()
                && !timed_out;
            store.finish_capture(session.meeting, success)?;
            self.last = json!({"meeting_id":session.meeting,"state":if success {"completed"}else{"failed"},"fragments":session.fragments,"saved_ms":session.base_ms+session.saved_frames*1000/session.sample_rate.max(1),"source":session.source["name"].as_str().unwrap_or("Микрофон по умолчанию"),"device":session.source,"staging_directory":session.directory,"error":if success {None}else{Some(session.error.unwrap_or_else(||"capture failed, timed out or produced no completed fragments".to_string()))}});
        }
        Ok(())
    }
}
impl Drop for CaptureManager {
    fn drop(&mut self) {
        if let Some(session) = self.active.as_mut() {
            let _ = session.child.kill();
            let _ = session.child.wait();
        }
    }
}
impl Store {
    pub fn register_capture_source(
        &self,
        meeting: i64,
        session: &str,
        source: &Value,
    ) -> Result<()> {
        let uid = source["uid"].as_str().context("missing microphone UID")?;
        let name = source["name"].as_str().context("missing microphone name")?;
        self.0.execute("INSERT INTO capture_sources(session_id,meeting_id,device_uid,device_name,source_json) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(session_id) DO NOTHING", rusqlite::params![session,meeting,uid,name,source.to_string()])?;
        Ok(())
    }
    fn begin_capture(&self, meeting: i64, continuation: bool) -> Result<()> {
        // SQLite serializes competing owners, including a second server process.
        let changed = self.0.execute("UPDATE meetings SET status='recording' WHERE id=?1 AND is_demo=0 AND ((?2=0 AND status IN ('created','failed')) OR (?2=1 AND status IN ('completed','failed') AND EXISTS(SELECT 1 FROM recordings WHERE meeting_id=?1))) AND NOT EXISTS (SELECT 1 FROM meetings WHERE status='recording') AND NOT EXISTS (SELECT 1 FROM processing_jobs WHERE status='running') AND NOT EXISTS(SELECT 1 FROM processing_jobs WHERE meeting_id=?1 AND status='pending')", rusqlite::params![meeting,continuation])?;
        if changed != 1 {
            bail!("meeting missing, completed or another recording owns the database");
        }
        Ok(())
    }
    fn finish_capture(&self, meeting: i64, success: bool) -> Result<()> {
        self.0.execute(
            "UPDATE meetings SET status=?2 WHERE id=?1 AND status='recording'",
            rusqlite::params![meeting, if success { "completed" } else { "failed" }],
        )?;
        Ok(())
    }
    /// Explicit operator recovery after confirming no capture process is still running.
    pub fn interrupt_capture(&self, meeting: i64) -> Result<()> {
        if self.0.execute(
            "UPDATE meetings SET status='failed' WHERE id=?1 AND status='recording'",
            [meeting],
        )? != 1
        {
            bail!("meeting is not recording");
        }
        Ok(())
    }
}
/// Local-only CLI client for the recording owner running in `serve`.
pub fn control(action: &str, meeting: i64, seconds: u64) -> Result<String> {
    control_device(action, meeting, seconds, None)
}
pub fn control_device(
    action: &str,
    meeting: i64,
    seconds: u64,
    device: Option<&str>,
) -> Result<String> {
    control_mode(action, meeting, seconds, device, None)
}
pub fn control_mode(
    action: &str,
    meeting: i64,
    seconds: u64,
    device: Option<&str>,
    mode: Option<&str>,
) -> Result<String> {
    use std::io::Read;
    let mut body = json!({"meeting_id":meeting,"seconds":seconds});
    if let Some(device) = device {
        body["device_uid"] = json!(device);
    }
    if let Some(mode) = mode {
        body["processing_mode"] = json!(mode);
    }
    let body = body.to_string();
    let address = crate::web::server_address()?;
    let origin = format!("http://{address}");
    let mut stream =
        std::net::TcpStream::connect(&address).context("start `vtracker serve` first")?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    write!(stream,"POST /api/recording/{action} HTTP/1.1\r\nHost: {address}\r\nOrigin: {origin}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len())?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    let (header, body) = response
        .split_once("\r\n\r\n")
        .context("invalid server response")?;
    if !header.starts_with("HTTP/1.1 200 ") {
        bail!("{body}");
    }
    Ok(body.to_string())
}
pub fn default_helper() -> PathBuf {
    std::env::var_os("VTRACKER_CAPTURE_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new("native/macos/.build/debug/vtracker-capture").to_owned())
}

/// Device inventory does not request microphone permission or start capture.
pub fn devices(helper: &Path) -> Result<Value> {
    let output = tempfile::NamedTempFile::new()?;
    let mut child = Command::new(helper)
        .arg("--devices")
        .stdin(Stdio::null())
        .stdout(Stdio::from(output.reopen()?))
        .stderr(Stdio::null())
        .spawn()
        .context("Не удалось получить список микрофонов; пересоберите адаптер macOS")?;
    let started = Instant::now();
    loop {
        if let Some(exit) = child.try_wait()? {
            if !exit.success() {
                bail!("Не удалось получить список микрофонов; проверьте адаптер macOS");
            }
            break;
        }
        if started.elapsed() > Duration::from_secs(5) {
            let _ = child.kill();
            let _ = child.wait();
            bail!("Адаптер не ответил на запрос списка микрофонов");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    if output.as_file().metadata()?.len() > 256 * 1024 {
        bail!("Слишком большой список микрофонов");
    }
    let value: Value = serde_json::from_reader(output.reopen()?)
        .context("Адаптер не поддерживает список устройств; пересоберите его")?;
    if !value.is_array() {
        bail!("Некорректный список микрофонов");
    }
    Ok(value)
}

#[derive(Default)]
pub struct MicrophoneTest {
    child: Option<Child>,
    events: Option<Receiver<String>>,
    started: Option<Instant>,
    state: Value,
}
impl MicrophoneTest {
    pub fn status(&self) -> Value {
        self.state.clone()
    }
    pub fn active(&self) -> bool {
        self.child.is_some()
    }
    pub fn start(&mut self, helper: &Path, device: &str, seconds: u64) -> Result<()> {
        if self.active() {
            bail!("Проверка микрофона уже выполняется");
        }
        if !(1..=30).contains(&seconds) {
            bail!("Проверка длится от 1 до 30 секунд");
        }
        let mut command = Command::new(helper);
        command.arg("--test").arg(seconds.to_string());
        if !device.is_empty() {
            command.arg(device);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdout = child.stdout.take().context("Нет связи с адаптером")?;
        let (sender, receiver) = mpsc::sync_channel(256);
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let _ = sender.try_send(line);
            }
        });
        self.child = Some(child);
        self.events = Some(receiver);
        self.started = Some(Instant::now());
        self.state =
            json!({"state":"starting","level":0,"peak":0,"seconds":seconds,"device_uid":device});
        Ok(())
    }
    pub fn poll(&mut self) -> Result<()> {
        if let Some(events) = &self.events {
            for line in events.try_iter() {
                if line == "READY" {
                    self.state["state"] = json!("testing");
                }
                if let Some(value) = line
                    .strip_prefix("DEVICE\t")
                    .and_then(|s| serde_json::from_str::<Value>(s).ok())
                {
                    self.state["device"] = value;
                }
                if let Some(value) = line
                    .strip_prefix("LEVEL\t")
                    .and_then(|s| s.parse::<f64>().ok())
                    .filter(|v| v.is_finite())
                {
                    let level = value.clamp(0.0, 1.0);
                    self.state["level"] = json!(level);
                    self.state["peak"] =
                        json!(level.max(self.state["peak"].as_f64().unwrap_or(0.0)));
                }
                if let Some(error) = line.strip_prefix("ERROR\t") {
                    self.state["error"] = json!(error);
                }
            }
        }
        if let Some(child) = &mut self.child {
            if self
                .started
                .is_some_and(|t| t.elapsed() > Duration::from_secs(90))
            {
                child.kill()?;
                self.state["error"] = json!("Проверка микрофона превысила время ожидания");
            }
            if let Some(exit) = child.try_wait()? {
                self.state["state"] = json!(if exit.success()
                    && self.state["error"].is_null()
                    && self.state["state"] == "testing"
                {
                    "completed"
                } else {
                    "failed"
                });
                if !exit.success() && self.state["error"].is_null() {
                    self.state["error"] = json!("Адаптер микрофона завершился с ошибкой");
                }
                self.child = None;
                self.events = None;
            }
        }
        Ok(())
    }
}
impl Drop for MicrophoneTest {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

pub(crate) fn microphone_lock(root: &Path) -> Result<std::fs::File> {
    use fs2::FileExt;
    std::fs::create_dir_all(root)?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.join(".microphone.lock"))?;
    lock.try_lock_exclusive()
        .context("Микрофон уже используется для записи встречи или голосового образца")?;
    Ok(lock)
}
