//! Ephemeral, local voice hints. Never writes identities or transcript assignments.
use crate::{
    audio::checksum,
    speech::run_command,
    voice::{normalize, quality, VoiceConfig},
    Store,
};
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};

type Outcome = std::result::Result<Value, String>;
pub struct LiveVoiceWorker {
    config: Option<VoiceConfig>,
    rx: Option<Receiver<Outcome>>,
    session: String,
    last_occurrence: i64,
    value: Value,
    received: Option<Instant>,
    last_person: Option<i64>,
    challenger: Option<i64>,
}
impl LiveVoiceWorker {
    pub fn new(config: Option<VoiceConfig>) -> Self {
        Self {
            config,
            rx: None,
            session: String::new(),
            last_occurrence: 0,
            value: Value::Null,
            received: None,
            last_person: None,
            challenger: None,
        }
    }
    pub fn fail(&mut self, reason: String) {
        self.challenger = None;
        self.value = json!({"status":"unknown","reason":reason});
        self.received = Some(Instant::now());
    }
    pub fn busy(&self) -> bool {
        self.rx.is_some()
    }
    pub fn status(&self) -> Value {
        let mut v = self.value.clone();
        if !v.is_null() {
            v["age_ms"] = json!(self
                .received
                .map(|t| t.elapsed().as_millis() as u64)
                .unwrap_or(0));
        }
        json!({"configured":self.config.is_some(),"running":self.busy(),"hint":v,"mode":"tentative-last-10-seconds"})
    }
    pub fn poll(
        &mut self,
        db: &Path,
        store: &Store,
        active: &Value,
        can_start: bool,
    ) -> Result<()> {
        let session = active["session_id"].as_str().unwrap_or("");
        if session != self.session {
            self.session = session.into();
            self.last_occurrence = 0;
            self.value = Value::Null;
            self.received = None;
            self.last_person = None;
            self.challenger = None;
        }
        let outcome = self.rx.as_ref().and_then(|rx| match rx.try_recv() {
            Ok(v) => Some(v),
            Err(mpsc::TryRecvError::Disconnected) => {
                Some(Err("Обработчик голоса завершился без результата".into()))
            }
            Err(mpsc::TryRecvError::Empty) => None,
        });
        if let Some(outcome) = outcome {
            self.rx = None;
            if let Ok(mut value) = outcome {
                if value["session_id"] == session && active["state"] == "recording" {
                    // A revoked/deleted profile cannot produce a visible name, even if it changed during inference.
                    if let Some(profile) = value["profile_id"].as_i64() {
                        let valid:bool=store.0.query_row("SELECT EXISTS(SELECT 1 FROM voice_profiles v JOIN meeting_people mp ON mp.person_id=v.person_id WHERE v.id=?1 AND mp.meeting_id=?2 AND EXISTS(SELECT 1 FROM voice_samples s JOIN voice_consents c ON c.id=s.consent_id WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND c.revoked_at IS NULL))",params![profile,active["meeting_id"].as_i64()],|r|r.get(0))?;
                        if !valid {
                            value["person_id"] = Value::Null;
                            value["profile_id"] = Value::Null;
                            value["status"] = json!("unknown");
                            value["reason"] = json!("Профиль удалён или согласие отозвано");
                        }
                    }
                    let person = value["person_id"].as_i64();
                    if person.is_some()
                        && self.last_person.is_some()
                        && person != self.last_person
                        && person != self.challenger
                    {
                        self.challenger = person;
                        value["status"] = json!("unknown");
                        value["person_id"] = Value::Null;
                        value["profile_id"] = Value::Null;
                        value["reason"] =
                            json!("Проверяем смену говорящего по следующему фрагменту");
                    } else {
                        if person.is_some() {
                            self.last_person = person;
                        }
                        self.challenger = None;
                    }
                    self.value = value;
                    self.received = Some(Instant::now());
                }
            } else if !session.is_empty() {
                self.challenger = None;
                self.value = json!({"status":"unknown","session_id":session,"reason":outcome.err().unwrap_or_default()});
                self.received = Some(Instant::now());
            }
        }
        if let Some(profile) = self.value["profile_id"].as_i64() {
            let valid:bool=store.0.query_row("SELECT EXISTS(SELECT 1 FROM voice_profiles v JOIN meeting_people mp ON mp.person_id=v.person_id WHERE v.id=?1 AND mp.meeting_id=?2 AND EXISTS(SELECT 1 FROM voice_samples s JOIN voice_consents c ON c.id=s.consent_id WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND c.revoked_at IS NULL))",params![profile,active["meeting_id"].as_i64()],|r|r.get(0))?;
            if !valid {
                self.value = json!({"status":"unknown","reason":"Согласие отозвано или участник исключён из встречи"});
            }
        }
        if active["state"] != "recording" {
            self.value = Value::Null;
            self.last_person = None;
            self.challenger = None;
            return Ok(());
        }
        if self.rx.is_some() || !can_start || self.config.is_none() {
            return Ok(());
        }
        let mid = active["meeting_id"]
            .as_i64()
            .context("Нет встречи для подсказки голоса")?;
        let allowed:bool=store.0.query_row("SELECT EXISTS(SELECT 1 FROM voice_profiles p JOIN meeting_people mp ON mp.person_id=p.person_id WHERE mp.meeting_id=?1)",[mid],|r|r.get(0))?;
        if !allowed {
            self.value = json!({"status":"unknown","reason":"Добавьте участников встречи с голосовыми профилями","session_id":session});
            return Ok(());
        }
        let last_id: i64 = store.0.query_row(
            "SELECT coalesce(max(id),0) FROM audio_timeline WHERE meeting_id=?1",
            [mid],
            |r| r.get(0),
        )?;
        if last_id == self.last_occurrence {
            return Ok(());
        }
        let inputs: Vec<_> = store
            .audio_inputs(mid)?
            .into_iter()
            .filter(|v| v["session_id"] == session)
            .collect();
        let Some(last) = inputs.last() else {
            return Ok(());
        };
        let occurrence = last["occurrence_id"].as_i64().unwrap_or(0);
        if occurrence == self.last_occurrence || inputs.len() < 2 {
            return Ok(());
        }
        self.last_occurrence = occurrence;
        let window = inputs[inputs.len() - 2..].to_vec();
        let settings = store.voice_matching_settings()?;
        let config = self.config.as_ref().unwrap();
        let config = VoiceConfig {
            engine: config.engine.clone(),
            model: config.model.clone(),
            ffmpeg: config.ffmpeg.clone(),
        };
        let db = db.to_owned();
        let session = session.to_owned();
        let (tx, rx) = mpsc::channel();
        self.rx = Some(rx);
        thread::spawn(move || {
            let result = analyze(&db, mid, &session, &window, &settings, &config)
                .map_err(|e| format!("Подсказка недоступна: {e}"));
            let _ = tx.send(result);
        });
        Ok(())
    }
}
fn analyze(
    db: &Path,
    mid: i64,
    session: &str,
    inputs: &[Value],
    settings: &Value,
    config: &VoiceConfig,
) -> Result<Value> {
    let dir = tempfile::Builder::new()
        .prefix("vtask-live-voice-")
        .tempdir()?;
    let model_hash = checksum(&config.model)?;
    let c = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut stmt=c.prepare("SELECT v.id,v.person_id,v.embedding_json FROM voice_profiles v JOIN meeting_people mp ON mp.person_id=v.person_id JOIN people p ON p.id=v.person_id WHERE mp.meeting_id=?1 AND p.is_demo=0 AND v.model_sha256=?2 AND v.revision=(SELECT max(x.revision) FROM voice_profiles x WHERE x.person_id=v.person_id AND x.model_sha256=v.model_sha256) AND EXISTS(SELECT 1 FROM voice_samples s JOIN voice_consents co ON co.id=s.consent_id WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND co.revoked_at IS NULL)")?;
    let profiles = stmt
        .query_map(params![mid, model_hash], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut result = json!({"session_id":session,"meeting_id":mid,"status":"unknown","person_id":null,"profile_id":null,"start_ms":inputs[0]["start_ms"],"end_ms":inputs.last().unwrap()["end_ms"],"reason":"Нет совместимых профилей с действующим согласием"});
    if profiles.is_empty() {
        return Ok(result);
    }
    let wav = dir.path().join("window.wav");
    let mut writer = hound::WavWriter::create(
        &wav,
        hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )?;
    for (i, input) in inputs.iter().enumerate() {
        let path = PathBuf::from(input["path"].as_str().context("Нет WAV")?);
        anyhow::ensure!(
            checksum(&path)? == input["sha256"].as_str().unwrap_or(""),
            "Повреждён фрагмент"
        );
        let part = dir.path().join(format!("{i}.wav"));
        run_command(
            Command::new(&config.ffmpeg)
                .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
                .arg(path)
                .args([
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-c:a",
                    "pcm_s16le",
                    "-threads",
                    "1",
                ])
                .arg(&part),
            Duration::from_secs(4),
        )?;
        for sample in hound::WavReader::open(part)?.samples::<i16>() {
            writer.write_sample(sample?)?;
        }
    }
    writer.finalize()?;
    if let Err(e) = quality(&wav) {
        result["reason"] = json!(e.to_string());
        return Ok(result);
    }
    let output = dir.path().join("vector.json");
    run_command(
        Command::new(&config.engine)
            .arg(&config.model)
            .arg(&wav)
            .arg(&output),
        Duration::from_secs(6),
    )?;
    let raw: Value = serde_json::from_reader(std::fs::File::open(output)?)?;
    let vector = normalize(
        &raw["embedding"]
            .as_array()
            .context("Нет вектора")?
            .iter()
            .map(|v| v.as_f64().context("Некорректный вектор"))
            .collect::<Result<Vec<_>>>()?,
    )?;
    let mut scores = Vec::new();
    for (profile, person, raw) in profiles {
        let values: Vec<f64> = serde_json::from_str(&raw)?;
        let values = normalize(&values)?;
        if values.len() == vector.len() {
            scores.push((
                vector.iter().zip(values).map(|(a, b)| a * b).sum::<f64>(),
                profile,
                person,
            ));
        }
    }
    scores.sort_by(|a, b| b.0.total_cmp(&a.0));
    let threshold = settings["threshold"].as_f64().unwrap_or(0.75);
    let margin = settings["margin"].as_f64().unwrap_or(0.1);
    if let Some(best) = scores.first() {
        result["similarity"] = json!(best.0);
        if best.0 >= threshold && scores.get(1).is_none_or(|next| best.0 - next.0 >= margin) {
            result["status"] = json!("candidate");
            result["person_id"] = json!(best.2);
            result["profile_id"] = json!(best.1);
            result["reason"]=json!("Предварительная подсказка по последним 10 секундам. Несколько голосов могут смешиваться; имя требует проверки.");
        } else {
            result["reason"] = if best.0 < threshold {
                json!(format!(
                    "Сходство голоса {:.2}, требуется {:.2}",
                    best.0, threshold
                ))
            } else {
                let difference = best.0 - scores[1].0;
                json!(format!(
                    "Голоса слишком похожи: отрыв {:.2}, требуется {:.2}",
                    difference, margin
                ))
            };
        }
    }
    Ok(result)
}
