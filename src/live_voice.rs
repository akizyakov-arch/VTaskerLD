//! Local voice hints. Stored as evidence separately from confirmed speaker assignments.
use crate::{
    audio::checksum,
    speech::run_command,
    voice::{normalize, voice_quality, VoiceConfig},
    Store,
};
use anyhow::{Context, Result};
use rusqlite::{params, Connection, OpenFlags};
use serde_json::{json, Value};
use std::{
    path::Path,
    process::Command,
    sync::mpsc::{self, Receiver},
    thread,
    time::{Duration, Instant},
};

type Outcome = std::result::Result<Value, String>;

impl Store {
    fn save_live_voice_hint(&self, hint: &Value) -> Result<()> {
        let (Some(occurrence), Some(meeting), Some(profile), Some(person), Some(start), Some(end), Some(score)) = (
            hint["occurrence_id"].as_i64(), hint["meeting_id"].as_i64(), hint["profile_id"].as_i64(),
            hint["person_id"].as_i64(), hint["start_ms"].as_i64(), hint["end_ms"].as_i64(), hint["similarity"].as_f64(),
        ) else { return Ok(()); };
        if end <= start || start < 0 { return Ok(()); }
        self.0.execute(
            "INSERT OR REPLACE INTO live_voice_hints(occurrence_id,meeting_id,profile_id,person_id,start_ms,end_ms,similarity)
             SELECT a.id,a.meeting_id,v.id,v.person_id,?5,?6,?7
             FROM audio_timeline a JOIN voice_profiles v ON v.id=?3 AND v.person_id=?4
             JOIN meeting_people mp ON mp.meeting_id=a.meeting_id AND mp.person_id=v.person_id
             WHERE a.id=?1 AND a.meeting_id=?2 AND EXISTS(
               SELECT 1 FROM voice_samples s JOIN voice_consents c ON c.id=s.consent_id
               WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND c.revoked_at IS NULL)",
            params![occurrence,meeting,profile,person,start,end,score],
        )?;
        Ok(())
    }

    pub(crate) fn transcript_live_voice_hints(&self, meeting: i64, run: i64) -> Result<Vec<Value>> {
        let mut statement = self.0.prepare(
            "SELECT h.start_ms,h.end_ms,h.person_id,p.name,h.profile_id,h.similarity
             FROM model_runs r JOIN json_each(r.inputs_json) i
             JOIN live_voice_hints h ON h.occurrence_id=json_extract(i.value,'$.occurrence_id') AND h.meeting_id=r.meeting_id
             JOIN people p ON p.id=h.person_id
             JOIN voice_profiles v ON v.id=h.profile_id AND v.person_id=h.person_id
             JOIN meeting_people mp ON mp.meeting_id=h.meeting_id AND mp.person_id=h.person_id
             WHERE r.meeting_id=?1 AND r.id=?2
               AND EXISTS(SELECT 1 FROM voice_samples s JOIN voice_consents c ON c.id=s.consent_id
                 WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND c.revoked_at IS NULL)
             ORDER BY h.start_ms,h.end_ms",
        )?;
        let rows = statement.query_map(params![meeting,run], |r| Ok(json!({
            "start_ms":r.get::<_,u64>(0)?,"end_ms":r.get::<_,u64>(1)?,"person_id":r.get::<_,i64>(2)?,
            "person_name":r.get::<_,String>(3)?,"profile_id":r.get::<_,i64>(4)?,"similarity":r.get::<_,f64>(5)?
        })))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

pub(crate) fn suggestion_from_live(start: u64, end: u64, hints: &[Value]) -> Option<Value> {
    if start >= end { return None; }
    let mut person = None;
    let mut best: Option<(&Value,u64)> = None;
    let mut spans = Vec::new();
    for hint in hints {
        let from = hint["start_ms"].as_u64()?.max(start);
        let to = hint["end_ms"].as_u64()?.min(end);
        let overlap = to.saturating_sub(from);
        if overlap < (end - start).min(400) { continue; }
        let id = hint["person_id"].as_i64()?;
        if person.is_some_and(|previous| previous != id) { return None; }
        person = Some(id);
        spans.push((from,to));
        if best.is_none_or(|(_,duration)| overlap > duration) { best = Some((hint,overlap)); }
    }
    let (hint, _) = best?;
    spans.sort_unstable();
    let mut covered = 0u64;
    let mut through = start;
    for (from,to) in spans {
        covered += to.saturating_sub(from.max(through));
        through = through.max(to);
    }
    if covered.saturating_mul(5) < (end - start).saturating_mul(3) { return None; }
    Some(json!({"status":"candidate","person_id":hint["person_id"],"person_name":hint["person_name"],
        "profile_id":hint["profile_id"],"similarity":hint["similarity"],"source":"live_voice",
        "reason":"Совпадение с голосовым профилем во время записи"}))
}

pub(crate) fn suggestion_for_segment(
    start: u64,
    end: u64,
    hints: &[Value],
    turns: &[Value],
    candidates: &[Value],
    matches: &[Value],
) -> Option<Value> {
    let live = suggestion_from_live(start, end, hints);
    if candidates.len() < 2 {
        return live;
    }

    let mut consensus: Option<Value> = None;
    for candidate in candidates {
        let matched = matches.iter().find(|entry| {
            entry["speaker_id"] == candidate["speaker_id"] && entry["status"] == "candidate"
        });
        let evidence = if candidate["assignment_source"] == "manual_speaker" {
            candidate["person_id"].as_i64()?;
            json!({"person_id":candidate["person_id"],"person_name":candidate["person_name"]})
        } else if let Some(matched) = matched {
            matched.clone()
        } else {
            let live = live.as_ref()?;
            for turn in turns.iter().filter(|turn| turn["speaker_id"] == candidate["speaker_id"]) {
                let from = start.max(turn["start_ms"].as_u64()?);
                let to = end.min(turn["end_ms"].as_u64()?);
                if from < to && suggestion_from_live(from, to, hints)
                    .is_none_or(|hint| hint["person_id"] != live["person_id"])
                {
                    return None;
                }
            }
            live.clone()
        };
        if consensus.as_ref().is_some_and(|previous| previous["person_id"] != evidence["person_id"])
            || live.as_ref().is_some_and(|hint| hint["person_id"] != evidence["person_id"])
        {
            return None;
        }
        if consensus.as_ref().is_none_or(|previous| {
            previous["similarity"].is_null() && !evidence["similarity"].is_null()
        }) {
            consensus = Some(evidence);
        }
    }
    consensus.map(|evidence| json!({
        "status":"candidate", "person_id":evidence["person_id"], "person_name":evidence["person_name"],
        "similarity":evidence["similarity"], "source":"segment_consensus",
        "reason":"Группы голоса в этой реплике совпали с одним участником"
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_coverage_without_counting_equal_windows_twice_or_overriding_conflicts() {
        let hint = |person,start,end| json!({"person_id":person,"start_ms":start,"end_ms":end,
            "person_name":"Участник","profile_id":person,"similarity":0.9});
        let a = hint(1,0,4500);
        let b = hint(1,3500,8500);
        assert_eq!(suggestion_from_live(0,10000,&[a.clone(),b]).unwrap()["person_id"],1);
        assert!(suggestion_from_live(0,10000,&[a.clone(),a.clone()]).is_none());
        assert!(suggestion_from_live(0,10000,&[a,hint(2,3500,10000)]).is_none());
    }
}
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
        json!({"configured":self.config.is_some(),"running":self.busy(),"hint":v,"mode":"tentative-latest-fragment"})
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
                    if value["status"] == "candidate" { store.save_live_voice_hint(&value)?; }
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
        if occurrence == self.last_occurrence {
            return Ok(());
        }
        self.last_occurrence = occurrence;
        let fragment = last.clone();
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
            let result = analyze(&db, mid, &session, &fragment, &settings, &config)
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
    fragment: &Value,
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
    let mut result = json!({"session_id":session,"meeting_id":mid,"status":"unknown","person_id":null,"profile_id":null,
        "start_ms":fragment["start_ms"],"end_ms":fragment["end_ms"],
        "occurrence_id":fragment["occurrence_id"],"reason":"Нет совместимых профилей с действующим согласием"});
    if profiles.is_empty() {
        return Ok(result);
    }
    let wav = dir.path().join("window.wav");
    let path = Path::new(fragment["path"].as_str().context("Нет WAV")?);
    anyhow::ensure!(
        checksum(path)? == fragment["sha256"].as_str().unwrap_or(""),
        "Повреждён фрагмент"
    );
    run_command(
        Command::new(&config.ffmpeg)
            .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
            .arg(path)
            .args(["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-threads", "1"])
            .arg(&wav),
        Duration::from_secs(4),
    )?;
    if let Err(e) = voice_quality(&wav, 4.0) {
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
            result["reason"] = json!("Совпадение с профилем по последнему фрагменту записи");
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
