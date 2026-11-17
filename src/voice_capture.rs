//! A consent-backed temporary microphone draft; it is never a meeting or a voice profile.
use crate::{
    speech::{resolve, run_command},
    voice::quality,
    Store,
};
use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde_json::{json, Value};
use std::{
    fs::{File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        mpsc::{self, Receiver},
        Arc,
    },
    time::{Duration, Instant},
};

const LIMIT: u64 = 45;
const TTL: Duration = Duration::from_secs(600);
// Three groups give each sample different words, rhythms, and intonations.
const ENROLLMENT_PHRASES: [[&str; 4]; 3] = [
    [
        "Сегодня утром над городом прошёл дождь, и на улице стало прохладнее.",
        "Вечером я открыл окно и услышал, как во дворе шелестят деревья.",
        "В субботу мы собираемся прогуляться по набережной и зайти в книжный магазин.",
        "На столе лежат карандаши, чистая тетрадь и несколько фотографий.",
    ],
    [
        "Скажи, пожалуйста, во сколько завтра открывается выставка?",
        "Ты уже решил, какую книгу взять с собой в поездку?",
        "Как ты думаешь, успеем ли мы вернуться домой до наступления темноты?",
        "Где лучше встретиться, у входа в парк или рядом с остановкой?",
    ],
    [
        "Сначала проверим список, потом спокойно обсудим каждый пункт и запишем решение.",
        "Положи ключи на полку, закрой дверь и напиши, когда доберёшься.",
        "Возьми синюю папку, найди нужный лист и прочитай последнюю строку.",
        "Если останется время, сравним варианты и выберем подходящий маршрут.",
    ],
];

#[derive(Default)]
struct PhrasePause {
    speech_ticks: u8,
    quiet_ticks: u8,
}

impl PhrasePause {
    fn advance(&mut self, level: f64) -> bool {
        // The capture helper sends a microphone level about every 200 ms.
        if level >= 0.012 {
            self.speech_ticks = self.speech_ticks.saturating_add(1);
            self.quiet_ticks = 0;
            return false;
        }
        if self.speech_ticks == 0 {
            return false;
        }
        self.quiet_ticks += 1;
        if self.quiet_ticks < 7 {
            return false;
        }
        let heard_speech = self.speech_ticks >= 5;
        *self = Self::default();
        heard_speech
    }
}

struct Draft {
    id: String,
    person: i64,
    phrases: [&'static str; 3],
    phrase_index: usize,
    phrase_pause: PhrasePause,
    directory: Arc<tempfile::TempDir>,
    child: Option<Child>,
    microphone_lock: Option<File>,
    events: Receiver<String>,
    conversion: Option<Receiver<std::result::Result<Value, String>>>,
    started: Instant,
    ready: Option<Instant>,
    stopping: Option<Instant>,
    finished: Option<Instant>,
    state: Value,
}
pub struct VoiceCapture {
    root: PathBuf,
    helper: PathBuf,
    ffmpeg: PathBuf,
    _lock: File,
    draft: Option<Draft>,
    last: Value,
    saved: Option<(String, i64, i64)>,
}
impl VoiceCapture {
    pub fn new(root: PathBuf, helper: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&root)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))?;
        }
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(root.join(".lock"))?;
        lock.try_lock_exclusive()
            .context("Другая панель уже использует запись голосовых образцов")?;
        // Holding the lock proves no earlier server owns these abandoned drafts.
        for entry in std::fs::read_dir(&root)? {
            let entry = entry?;
            if entry.file_name().to_string_lossy().starts_with("draft-")
                && entry.file_type()?.is_dir()
            {
                std::fs::remove_dir_all(entry.path())?;
            }
        }
        let ffmpeg = std::env::var_os("VTRACKER_FFMPEG_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| "ffmpeg".into());
        Ok(Self {
            root,
            helper,
            ffmpeg,
            _lock: lock,
            draft: None,
            last: Value::Null,
            saved: None,
        })
    }
    pub fn busy(&self) -> bool {
        self.draft
            .as_ref()
            .is_some_and(|d| d.child.is_some() || d.conversion.is_some())
    }
    pub fn person(&self) -> Option<i64> {
        self.draft.as_ref().map(|d| d.person)
    }
    pub fn status(&self) -> Value {
        let draft = self.draft.as_ref().map(|d| {
            let mut v = d.state.clone();
            v["id"] = json!(d.id);
            v["person_id"] = json!(d.person);
            v["limit_seconds"] = json!(LIMIT);
            v["phrases"] = json!(d.phrases);
            v["phrase_index"] = json!(d.phrase_index);
            if d.child.is_some() {
                v["elapsed_ms"] = json!(d.ready.map_or(0, |t| t.elapsed().as_millis()));
            }
            v["expires_in_seconds"] = json!(d
                .finished
                .map(|t| TTL.saturating_sub(t.elapsed()).as_secs()));
            v
        });
        json!({"draft":draft,"last":self.last})
    }
    pub fn start(
        &mut self,
        store: &Store,
        person: i64,
        device: &str,
        consent: bool,
    ) -> Result<Value> {
        if !consent {
            bail!("Нужно согласие участника на запись образца и создание голосового профиля");
        }
        if self.draft.is_some() {
            bail!("Сначала сохраните или отмените предыдущий голосовой образец");
        }
        let real: bool = store
            .0
            .query_row("SELECT is_demo=0 FROM people WHERE id=?1", [person], |r| {
                r.get(0)
            })
            .context("Участник не найден")?;
        if !real {
            bail!("В деморежиме запись образца недоступна");
        }
        let microphone_lock = crate::capture::microphone_lock(
            &self.root.parent().unwrap_or(Path::new(".")).join("audio"),
        )?;
        let busy:bool=store.0.query_row("SELECT EXISTS(SELECT 1 FROM meetings WHERE status='recording') OR EXISTS(SELECT 1 FROM processing_jobs WHERE status='running') OR EXISTS(SELECT 1 FROM voice_jobs WHERE state='running') OR EXISTS(SELECT 1 FROM voice_match_jobs WHERE state='running') OR EXISTS(SELECT 1 FROM live_chunks WHERE state='running')",[],|r|r.get(0))?;
        if busy {
            bail!("Дождитесь окончания записи и другой обработки");
        }
        self.ffmpeg = resolve(&self.ffmpeg)?;
        let directory = Arc::new(
            tempfile::Builder::new()
                .prefix("draft-")
                .tempdir_in(&self.root)?,
        );
        let mut random = [0u8; 16];
        File::open("/dev/urandom")?.read_exact(&mut random)?;
        use std::fmt::Write as _;
        let mut id = String::with_capacity(32);
        for byte in random {
            write!(&mut id, "{byte:02x}")?;
        }
        let mut command = Command::new(&self.helper);
        command.arg(directory.path()).arg(LIMIT.to_string());
        if !device.is_empty() {
            command.arg(device);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("Не удалось запустить микрофон для образца")?;
        let stdout = child.stdout.take().context("Нет связи с микрофоном")?;
        let (tx, events) = mpsc::sync_channel(256);
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let _ = tx.try_send(line);
            }
        });
        self.last = Value::Null;
        let phrases = std::array::from_fn(|i| {
            ENROLLMENT_PHRASES[i][usize::from(random[i]) % ENROLLMENT_PHRASES[i].len()]
        });
        self.draft = Some(Draft {
            phrases,
            phrase_index: 0,
            phrase_pause: PhrasePause::default(),
            id,
            person,
            directory,
            child: Some(child),
            microphone_lock: Some(microphone_lock),
            events,
            conversion: None,
            started: Instant::now(),
            ready: None,
            stopping: None,
            finished: None,
            state: json!({"state":"starting","level":0,"device_uid":device,"elapsed_ms":0}),
        });
        Ok(self.status())
    }
    fn check(&self, id: &str, person: i64) -> Result<()> {
        let d = self
            .draft
            .as_ref()
            .context("Образец не найден или уже удалён")?;
        if d.id != id || d.person != person {
            bail!("Образец относится к другой процедуре или участнику");
        }
        Ok(())
    }
    pub fn next_phrase(&mut self, id: &str, person: i64, expected: u64) -> Result<Value> {
        self.check(id, person)?;
        let draft = self.draft.as_mut().unwrap();
        if draft.state["state"] == "recording" && draft.phrase_index as u64 == expected
            && draft.phrase_index < draft.phrases.len()
        {
            draft.phrase_index += 1;
            draft.phrase_pause = PhrasePause::default();
        }
        Ok(self.status())
    }
    pub fn stop(&mut self, id: &str, person: i64) -> Result<Value> {
        self.check(id, person)?;
        let d = self.draft.as_mut().unwrap();
        if let Some(child) = &mut d.child {
            if d.stopping.is_none() {
                child
                    .stdin
                    .as_mut()
                    .context("Нет связи с микрофоном")?
                    .write_all(b"stop\n")?;
                d.stopping = Some(Instant::now());
                d.state["state"] = json!("stopping");
            }
        }
        Ok(self.status())
    }
    pub fn cancel(&mut self, id: &str, person: i64) -> Result<()> {
        self.check(id, person)?;
        let mut d = self.draft.take().unwrap();
        if let Some(child) = &mut d.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(d.directory.path());
        self.last = json!({"person_id":person,"state":"cancelled"});
        Ok(())
    }
    pub fn discard_person(&mut self, person: i64) -> Result<()> {
        if let Some(d) = &self.draft {
            if d.person == person {
                let id = d.id.clone();
                self.cancel(&id, person)?;
            }
        }
        if self.saved.as_ref().is_some_and(|(_, p, _)| *p == person) {
            self.saved = None;
        }
        Ok(())
    }
    pub fn audio(&self, id: &str) -> Result<PathBuf> {
        let d = self.draft.as_ref().context("Образец уже удалён")?;
        if d.id != id || !matches!(d.state["state"].as_str(), Some("ready" | "rejected")) {
            bail!("Образец ещё не готов к прослушиванию");
        }
        let path = d.directory.path().join("sample.wav");
        if !path.is_file() {
            bail!("Запись образца недоступна");
        }
        Ok(path)
    }
    pub fn accept(
        &mut self,
        store: &Store,
        id: &str,
        person: i64,
        voice_root: &Path,
        consent: bool,
        solo: bool,
    ) -> Result<i64> {
        if !consent || !solo {
            bail!("Подтвердите согласие участника и что в образце только его голос");
        }
        if let Some((saved, owner, job)) = &self.saved {
            if saved == id && *owner == person {
                return Ok(*job);
            }
        }
        self.check(id, person)?;
        let d = self.draft.as_ref().unwrap();
        if d.state["state"] != "ready" {
            bail!("Образец не прошёл проверку. Запишите его заново");
        }
        let job = store.queue_voice_sample(person, &self.audio(id)?, voice_root, consent, solo)?;
        // queue_voice_sample durably copies the input before the temporary directory is dropped.
        self.saved = Some((id.to_string(), person, job));
        self.draft = None;
        self.last = json!({"person_id":person,"state":"queued","job_id":job});
        Ok(job)
    }
    pub fn poll(&mut self) -> Result<()> {
        let Some(d) = &mut self.draft else {
            return Ok(());
        };
        let mut stream_closed = false;
        loop {
            let line = match d.events.try_recv() {
                Ok(line) => line,
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    stream_closed = true;
                    break;
                }
            };
            if line == "READY" && d.ready.is_none() {
                d.ready = Some(Instant::now());
                if d.stopping.is_none() {
                    d.state["state"] = json!("recording");
                }
            }
            if let Some(device) = line
                .strip_prefix("DEVICE\t")
                .and_then(|v| serde_json::from_str::<Value>(v).ok())
            {
                d.state["device"] = device;
            }
            if let Some(level) = line
                .strip_prefix("LEVEL\t")
                .and_then(|v| v.parse::<f64>().ok())
                .filter(|v| v.is_finite())
            {
                d.state["level"] = json!(level.clamp(0.0, 1.0));
                if d.state["state"] == "recording"
                    && d.phrase_index < d.phrases.len()
                    && d.phrase_pause.advance(level)
                {
                    d.phrase_index += 1;
                }
            }
            if let Some(error) = line.strip_prefix("ERROR\t") {
                d.state["error"] = json!(error);
            }
        }
        if let Some(child) = &mut d.child {
            if d.stopping.is_none()
                && d.ready
                    .is_some_and(|t| t.elapsed() >= Duration::from_secs(LIMIT))
            {
                if let Some(input) = &mut child.stdin {
                    let _ = input.write_all(b"stop\n");
                }
                d.stopping = Some(Instant::now());
                d.state["state"] = json!("stopping");
            }
            let timed_out = if let Some(stopping) = d.stopping {
                stopping.elapsed() > Duration::from_secs(8)
            } else {
                d.started.elapsed() > Duration::from_secs(LIMIT + 90)
            };
            if timed_out {
                let _ = child.kill();
                d.state["error"] = json!("Микрофон не завершил запись вовремя. Попробуйте снова");
            }
            let exit = match child.try_wait() {
                Ok(exit) => exit,
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    d.child = None;
                    d.microphone_lock = None;
                    d.state["state"] = json!("failed");
                    d.state["error"] =
                        json!(format!("Не удалось завершить запись образца: {error}"));
                    d.finished = Some(Instant::now());
                    return Ok(());
                }
            };
            if let Some(exit) = exit {
                if !stream_closed {
                    return Ok(());
                }
                d.child = None;
                d.microphone_lock = None;
                d.state["elapsed_ms"] = json!(d.ready.map_or(0, |t| t.elapsed().as_millis()));
                if !exit.success() || d.ready.is_none() || !d.state["error"].is_null() {
                    d.state["state"] = json!("failed");
                    d.finished = Some(Instant::now());
                    if d.state["error"].is_null() {
                        d.state["error"] =
                            json!("Запись образца не удалась. Проверьте доступ к микрофону");
                    }
                } else {
                    d.state["state"] = json!("preparing");
                    let directory = d.directory.clone();
                    let ffmpeg = self.ffmpeg.clone();
                    let (tx, rx) = mpsc::channel();
                    d.conversion = Some(rx);
                    std::thread::spawn(move || {
                        let result = prepare(directory.path(), &ffmpeg).map_err(|e| e.to_string());
                        let _ = tx.send(result);
                    });
                }
            }
        }
        if let Some(rx) = &d.conversion {
            match rx.try_recv() {
                Ok(result) => {
                    d.conversion = None;
                    d.finished = Some(Instant::now());
                    match result {
                        Ok(q) => {
                            d.state["quality"] = q;
                            d.state["state"] = json!("ready");
                        }
                        Err(e) => {
                            d.state["state"] =
                                json!(if d.directory.path().join("sample.wav").is_file() {
                                    "rejected"
                                } else {
                                    "failed"
                                });
                            d.state["error"] = json!(e);
                        }
                    }
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    d.conversion = None;
                    d.finished = Some(Instant::now());
                    d.state["state"] = json!("failed");
                    d.state["error"] = json!("Не удалось подготовить образец");
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        if d.finished.is_some_and(|t| t.elapsed() > TTL) {
            let person = d.person;
            self.draft = None;
            self.last = json!({"person_id":person,"state":"expired","error":"Временный образец удалён через 10 минут. Запишите новый"});
        }
        Ok(())
    }
}
impl Drop for VoiceCapture {
    fn drop(&mut self) {
        if let Some(d) = &mut self.draft {
            if let Some(child) = &mut d.child {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}
fn prepare(directory: &Path, ffmpeg: &Path) -> Result<Value> {
    let mut inputs = Vec::new();
    for entry in std::fs::read_dir(directory)? {
        let e = entry?;
        let name = e.file_name();
        let name = name.to_string_lossy();
        if e.file_type()?.is_file()
            && name.len() == 10
            && name.ends_with(".wav")
            && name.bytes().take(6).all(|b| b.is_ascii_digit())
        {
            inputs.push(e.path());
        }
    }
    inputs.sort();
    if inputs.is_empty() || inputs.len() > 12 {
        bail!("Нет сохранённой речи для образца");
    }
    let sample = directory.join("sample.wav");
    let mut merged = hound::WavWriter::create(
        &sample,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )?;
    let mut total = 0u64;
    for (i, input) in inputs.iter().enumerate() {
        if std::fs::metadata(input)?.len() > 32 * 1024 * 1024 {
            bail!("Слишком большой фрагмент образца");
        }
        let normalized = directory.join(format!("normalized-{i}.wav"));
        run_command(
            Command::new(ffmpeg)
                .args([
                    "-nostdin",
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-threads",
                    "1",
                    "-i",
                ])
                .arg(input)
                .args(["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"])
                .arg(&normalized),
            Duration::from_secs(10),
        )?;
        let mut wav = hound::WavReader::open(normalized)?;
        for sample in wav.samples::<i16>() {
            total += 1;
            if total > 60 * 16000 {
                bail!("Образец длиннее одной минуты");
            }
            merged.write_sample(sample?)?;
        }
    }
    merged.finalize()?;
    quality(&sample)
}

#[cfg(test)]
mod expiry_tests {
    use super::*;
    #[test]
    fn pause_advances_once_only_after_speech() {
        let mut pause = PhrasePause::default();
        for _ in 0..12 { assert!(!pause.advance(0.001)); }
        assert!(!pause.advance(0.1));
        for _ in 0..8 { assert!(!pause.advance(0.001)); }

        for _ in 0..5 { assert!(!pause.advance(0.06)); }
        for _ in 0..6 { assert!(!pause.advance(0.001)); }
        assert!(!pause.advance(0.06));
        for _ in 0..6 { assert!(!pause.advance(0.001)); }
        assert!(pause.advance(0.001));
        for _ in 0..12 { assert!(!pause.advance(0.001)); }
    }

    #[test]
    fn expired_draft_is_removed_without_creating_a_profile() {
        let root = tempfile::tempdir().unwrap();
        let mut manager = VoiceCapture::new(root.path().join("drafts"), "unused".into()).unwrap();
        let directory = Arc::new(
            tempfile::Builder::new()
                .prefix("draft-")
                .tempdir_in(&manager.root)
                .unwrap(),
        );
        let path = directory.path().to_path_buf();
        std::fs::write(path.join("sample.wav"), b"temporary").unwrap();
        let (tx, events) = mpsc::channel();
        drop(tx);
        manager.draft = Some(Draft {
            id: "expired".into(),
            phrases: ENROLLMENT_PHRASES.map(|group| group[0]),
            phrase_index: 0,
            phrase_pause: PhrasePause::default(),
            person: 1,
            directory,
            child: None,
            microphone_lock: None,
            events,
            conversion: None,
            started: Instant::now(),
            ready: None,
            stopping: None,
            finished: Some(Instant::now() - TTL - Duration::from_secs(1)),
            state: json!({"state":"ready"}),
        });
        manager.poll().unwrap();
        assert!(manager.status()["draft"].is_null());
        assert_eq!(manager.status()["last"]["state"], "expired");
        assert!(!path.exists());
    }
}
