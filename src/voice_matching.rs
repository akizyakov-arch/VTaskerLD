//! Consent-backed excerpts and reviewable voice matches. Never writes manual assignments.
use crate::{
    audio::checksum,
    speech::run_command,
    voice::{normalize, voice_quality, VoiceConfig},
    Store,
};
use anyhow::{bail, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::{collections::BTreeSet, path::Path, process::Command, time::Duration};

const MIN_ENROLLMENT_MS: u64 = 6000;

fn selected_voice_excerpt(run: i64, ids: &BTreeSet<i64>, mut ranges: Vec<(u64, u64)>) -> Result<Value> {
    ranges.sort_unstable();
    let mut merged: Vec<(u64, u64)> = Vec::new();
    for (start, end) in ranges {
        if let Some(last) = merged.last_mut().filter(|last| start <= last.1) {
            last.1 = last.1.max(end);
        } else {
            merged.push((start, end));
        }
    }
    let duration: u64 = merged.iter().map(|(start, end)| end - start).sum();
    if !(MIN_ENROLLMENT_MS..=60_000).contains(&duration) {
        bail!("Для голосового образца выберите от 6 до 60 секунд речи");
    }
    let mut intervals = Vec::new();
    for (mut start, end) in merged {
        while start < end {
            let stop = end.min(start + 30_000);
            intervals.push(json!({"start_ms":start,"end_ms":stop}));
            start = stop;
        }
    }
    Ok(json!({"kind":"meeting_fragments","model_run_id":run,"segment_ids":ids,
              "duration_ms":duration,"intervals":intervals}))
}

fn queue_voice_excerpt(db: &rusqlite::Connection, person: i64, source: &Value) -> Result<i64> {
    let source_json = source.to_string();
    let existing = db.query_row(
        "SELECT j.id FROM voice_jobs j JOIN voice_consents c ON c.id=j.consent_id
         WHERE j.person_id=?1 AND j.source_json=?2 AND c.revoked_at IS NULL
           AND j.state IN ('pending','running','completed') ORDER BY j.id DESC LIMIT 1",
        params![person, source_json], |row| row.get(0),
    ).optional()?;
    if let Some(id) = existing {
        return Ok(id);
    }
    crate::voice::require_voice_sample_capacity(db, person, Some(source))?;
    db.execute("INSERT INTO voice_consents(person_id,source_json) VALUES (?1,?2)", params![person, source_json])?;
    let consent_id = db.last_insert_rowid();
    db.execute("INSERT INTO voice_jobs(person_id,consent_id,input_path,source_json) VALUES (?1,?2,'',?3)",
        params![person, consent_id, source_json])?;
    Ok(db.last_insert_rowid())
}

fn clean_ranges(turns: &[(u64, u64, String)], speaker: &str) -> Vec<(u64, u64)> {
    let mut selected: Vec<(u64, u64)> = turns
        .iter()
        .filter(|t| t.2 == speaker)
        .map(|t| (t.0, t.1))
        .collect();
    selected.sort();
    let mut merged: Vec<(u64, u64)> = Vec::new();
    for (start, end) in selected {
        if let Some(last) = merged.last_mut().filter(|last| start <= last.1) {
            last.1 = last.1.max(end);
        } else {
            merged.push((start, end));
        }
    }
    for (other_start, other_end, other) in turns {
        if other == speaker {
            continue;
        }
        let mut next = Vec::new();
        for (start, end) in merged {
            if *other_end <= start || *other_start >= end {
                next.push((start, end));
            } else {
                if start < *other_start {
                    next.push((start, *other_start));
                }
                if *other_end < end {
                    next.push((*other_end, end));
                }
            }
        }
        merged = next;
    }
    merged.retain(|(a, b)| b - a >= 800);
    // Prefer longer continuous stretches, then restore chronological playback order.
    merged.sort_by_key(|(a, b)| std::cmp::Reverse(b - a));
    let mut remaining = 30000;
    let mut picked = Vec::new();
    for (a, b) in merged {
        let take = (b - a).min(remaining);
        if take >= 800 {
            picked.push((a, a + take));
            remaining -= take;
        }
        if remaining < 800 {
            break;
        }
    }
    picked.sort();
    picked
}
impl Store {
    pub fn voice_matching_settings(&self) -> Result<Value> {
        let raw: Option<String> = self
            .0
            .query_row(
                "SELECT data_json FROM workspace_settings WHERE key='voice_matching'",
                [],
                |r| r.get(0),
            )
            .optional()?;
        Ok(match raw {
            Some(raw) => serde_json::from_str(&raw)?,
            None => json!({"enabled":true,"threshold":0.75,"margin":0.1}),
        })
    }
    pub fn save_voice_matching_settings(&self, data: &Value) -> Result<Value> {
        let enabled = data["enabled"]
            .as_bool()
            .context("Выберите режим голосового сопоставления")?;
        let threshold = data["threshold"]
            .as_f64()
            .context("Укажите порог сходства")?;
        let margin = data["margin"]
            .as_f64()
            .context("Укажите отрыв от второго кандидата")?;
        if !(0.5..=0.99).contains(&threshold) || !(0.05..=0.5).contains(&margin) {
            bail!("Порог должен быть 0,50–0,99, отрыв — 0,05–0,50");
        }
        let value = json!({"enabled":enabled,"threshold":threshold,"margin":margin});
        self.0.execute("INSERT INTO workspace_settings(key,data_json) VALUES ('voice_matching',?1) ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",[value.to_string()])?;
        Ok(value)
    }
    pub fn voice_source_plan(&self, run: i64, speaker: &str) -> Result<Value> {
        self.voice_source_plan_with_minimum(run, speaker, MIN_ENROLLMENT_MS)
    }

    pub fn voice_source_preview(&self, run: i64, speaker: &str) -> Result<Value> {
        let mut plan = self.voice_source_plan_with_minimum(run, speaker, 0)?;
        plan["minimum_enrollment_ms"] = json!(MIN_ENROLLMENT_MS);
        Ok(plan)
    }

    fn voice_source_plan_with_minimum(&self, run: i64, speaker: &str, minimum_ms: u64) -> Result<Value> {
        let real:bool=self.0.query_row("SELECT m.status='completed' AND meet.is_demo=0 FROM model_runs m JOIN meetings meet ON meet.id=m.meeting_id WHERE m.id=?1",[run],|r|r.get(0)).context("Завершённая обработка встречи не найдена")?;
        if !real {
            bail!("Выберите завершённую обработку реальной встречи");
        }
        let mut stmt=self.0.prepare("SELECT start_ms,end_ms,speaker_id FROM speaker_turns WHERE model_run_id=?1 ORDER BY start_ms,id")?;
        let turns: Vec<(u64, u64, String)> = stmt
            .query_map([run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        if !turns.iter().any(|t| t.2 == speaker) {
            bail!("Говорящий не найден в этой версии встречи");
        }
        let ranges = clean_ranges(&turns, speaker);
        let duration: u64 = ranges.iter().map(|(a, b)| b - a).sum();
        if duration < minimum_ms {
            bail!("Недостаточно чистой речи этого голоса без пересечений (нужно не менее {} секунд)", minimum_ms / 1000);
        }
        Ok(
            json!({"kind":"meeting","model_run_id":run,"speaker_id":speaker,"duration_ms":duration,"intervals":ranges.into_iter().map(|(start,end)|json!({"start_ms":start,"end_ms":end})).collect::<Vec<_>>()}),
        )
    }
    pub fn queue_voice_from_meeting(
        &self,
        person: i64,
        run: i64,
        speaker: &str,
        consent: bool,
        single_speaker: bool,
    ) -> Result<i64> {
        if !consent || !single_speaker {
            bail!("Подтвердите согласие участника и что выбранные фрагменты содержат только его голос");
        }
        let real: bool = self
            .0
            .query_row("SELECT is_demo=0 FROM people WHERE id=?1", [person], |r| {
                r.get(0)
            })
            .context("Участник не найден")?;
        if !real {
            bail!("Для демонстрационного участника профиль не создаётся");
        }
        let source = self.voice_source_plan(run, speaker)?;
        let tx = self.0.unchecked_transaction()?;
        let id = queue_voice_excerpt(&tx, person, &source)?;
        tx.commit()?;
        Ok(id)
    }

    pub fn assign_voice_fragments(
        &self,
        run: i64,
        segments: &[i64],
        person: i64,
        assign: bool,
        enrollment: Option<&Value>,
    ) -> Result<Value> {
        let ids: BTreeSet<_> = segments.iter().copied().collect();
        if ids.is_empty() {
            bail!("Выберите хотя бы одну реплику");
        }
        if !assign && enrollment.is_none() {
            bail!("Выберите назначение реплик или сохранение образца");
        }
        let tx = self.0.unchecked_transaction()?;
        let valid: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM model_runs r JOIN meetings m ON m.id=r.meeting_id
             JOIN people p ON p.id=?2 AND p.is_demo=m.is_demo WHERE r.id=?1 AND r.status='completed')",
            params![run, person], |row| row.get(0),
        )?;
        if !valid { bail!("Участник или завершённая версия расшифровки не найдены"); }
        let mut job = None;
        if let Some(enrollment) = enrollment {
            if enrollment["consent"] != true || enrollment["single_speaker"] != true {
                bail!("Подтвердите согласие участника и что в выбранных репликах звучит только его голос");
            }
            let real: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM model_runs r JOIN meetings m ON m.id=r.meeting_id
                 WHERE r.id=?1 AND r.status='completed' AND m.is_demo=0)",
                [run], |row| row.get(0),
            )?;
            if !real { bail!("Выберите завершённую обработку реальной встречи"); }
            let mut ranges = Vec::new();
            for id in &ids {
                let interval = tx.query_row(
                    "SELECT start_ms,end_ms FROM segments WHERE model_run_id=?1 AND id=?2",
                    params![run, id],
                    |row| Ok((row.get::<_, u64>(0)?, row.get::<_, u64>(1)?)),
                ).context("Выбранная реплика отсутствует в этой версии расшифровки")?;
                if interval.1 > interval.0 { ranges.push(interval); }
            }
            let source = selected_voice_excerpt(run, &ids, ranges)?;
            job = Some(queue_voice_excerpt(&tx, person, &source)?);
        }
        for id in ids.iter().filter(|_| assign) {
            let assigned: Option<i64> = tx.query_row(
                "SELECT person_id FROM segment_assignments
                 WHERE model_run_id=?1 AND segment_id=?2 ORDER BY id DESC LIMIT 1",
                params![run, id], |row| row.get::<_, Option<i64>>(0),
            ).optional()?.flatten();
            if assigned != Some(person) {
                self.assign_segment(run, *id, Some(person))?;
            }
        }
        tx.commit()?;
        Ok(json!({"assigned":if assign {ids.len()} else {0},"job_id":job}))
    }
    pub(crate) fn prepare_voice_excerpt(
        &self,
        source: &Value,
        output: &Path,
        scratch: &Path,
        config: &VoiceConfig,
    ) -> Result<()> {
        let run = source["model_run_id"]
            .as_i64()
            .context("Не указана версия встречи")?;
        let raw: String = self.0.query_row(
            "SELECT inputs_json FROM model_runs WHERE id=?1 AND status='completed'",
            [run],
            |r| r.get(0),
        )?;
        let inputs: Value = serde_json::from_str(&raw)?;
        let inputs = inputs
            .as_array()
            .context("Отсутствуют источники аудио встречи")?;
        let ranges = source["intervals"]
            .as_array()
            .context("Не выбраны голосовые фрагменты")?;
        let mut writer = hound::WavWriter::create(
            output,
            hound::WavSpec {
                channels: 1,
                sample_rate: 16000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )?;
        let mut sequence = 0;
        let mut verified = BTreeSet::new();
        for range in ranges {
            let start = range["start_ms"].as_u64().context("Некорректный таймкод")?;
            let end = range["end_ms"].as_u64().context("Некорректный таймкод")?;
            if end <= start || end - start > 30000 {
                bail!("Некорректный голосовой фрагмент");
            }
            for input in inputs {
                let a = input["start_ms"]
                    .as_u64()
                    .context("Нет таймкода аудиоисточника")?;
                let b = input["end_ms"]
                    .as_u64()
                    .context("Нет таймкода аудиоисточника")?;
                let left = start.max(a);
                let right = end.min(b);
                if left >= right {
                    continue;
                }
                let path = input["path"].as_str().context("Нет аудиоисточника")?;
                if verified.insert(path.to_string())
                    && checksum(Path::new(path))? != input["sha256"].as_str().unwrap_or_default()
                {
                    bail!("Контрольная сумма исходной записи не совпала");
                }
                let piece = scratch.join(format!("voice-piece-{sequence}.wav"));
                sequence += 1;
                run_command(
                    Command::new(&config.ffmpeg)
                        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-ss"])
                        .arg(format!("{:.3}", (left - a) as f64 / 1000.0))
                        .arg("-t")
                        .arg(format!("{:.3}", (right - left) as f64 / 1000.0))
                        .arg("-i")
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
                        .arg(&piece),
                    Duration::from_secs(10),
                )?;
                let mut wav = hound::WavReader::open(piece)?;
                for value in wav.samples::<i16>() {
                    writer.write_sample(value?)?;
                }
            }
        }
        writer.finalize()?;
        Ok(())
    }
    pub fn queue_voice_matching(&self, run: i64) -> Result<i64> {
        let valid:bool=self.0.query_row("SELECT m.status='completed' AND meet.is_demo=0 AND EXISTS(SELECT 1 FROM speaker_turns WHERE model_run_id=m.id) FROM model_runs m JOIN meetings meet ON meet.id=m.meeting_id WHERE m.id=?1",[run],|r|r.get(0)).context("Обработка встречи не найдена")?;
        if !valid {
            bail!("Для сопоставления нужен итоговый транскрипт с разделением голосов");
        }
        let settings = self.voice_matching_settings()?;
        let inserted = self.0.execute(
            "INSERT INTO voice_match_jobs(model_run_id,threshold,margin) VALUES (?1,?2,?3) ON CONFLICT DO NOTHING",
            params![
                run,
                settings["threshold"].as_f64().unwrap(),
                settings["margin"].as_f64().unwrap()
            ],
        )?;
        if inserted == 1 {
            return Ok(self.0.last_insert_rowid());
        }
        Ok(self.0.query_row(
            "SELECT id FROM voice_match_jobs WHERE model_run_id=?1 AND state IN ('pending','running')",
            [run], |row| row.get(0),
        )?)
    }

    pub fn latest_voice_match_job(&self, run: i64) -> Result<Option<Value>> {
        Ok(self.0.query_row(
            "SELECT id,state,error FROM voice_match_jobs WHERE model_run_id=?1 ORDER BY id DESC LIMIT 1",
            [run],
            |row| Ok(json!({"id":row.get::<_,i64>(0)?,"model_run_id":run,
                           "state":row.get::<_,String>(1)?,"error":row.get::<_,Option<String>>(2)?})),
        ).optional()?)
    }

    pub(crate) fn refresh_voice_matches_after_enrollment(&self, source_run: i64, person: i64) -> Result<()> {
        if !self.speaker_detection_enabled()? || self.voice_matching_settings()?["enabled"] != true {
            return Ok(());
        }
        let latest: Option<i64> = self.0.query_row(
            "SELECT r.id FROM model_runs src JOIN model_runs r ON r.meeting_id=src.meeting_id
             WHERE src.id=?1 AND r.status='completed'
               AND (NOT EXISTS(SELECT 1 FROM meeting_people WHERE meeting_id=r.meeting_id)
                    OR EXISTS(SELECT 1 FROM meeting_people WHERE meeting_id=r.meeting_id AND person_id=?2))
             ORDER BY r.id DESC LIMIT 1",
            params![source_run, person], |row| row.get(0),
        ).optional()?;
        if let Some(run) = latest {
            let has_speakers: bool = self.0.query_row(
                "SELECT EXISTS(SELECT 1 FROM speaker_turns WHERE model_run_id=?1)", [run], |row| row.get(0),
            )?;
            if has_speakers {
                self.queue_voice_matching(run)?;
            }
        }
        Ok(())
    }

    pub(crate) fn voice_enrollment_pending_for_run(&self, run: i64) -> Result<bool> {
        Ok(self.0.query_row(
            "SELECT EXISTS(SELECT 1 FROM model_runs current JOIN model_runs source ON source.meeting_id=current.meeting_id
             JOIN voice_jobs j ON json_extract(j.source_json,'$.model_run_id')=source.id
             WHERE current.id=?1 AND j.state IN ('pending','running'))",
            [run], |row| row.get(0),
        )?)
    }

    pub fn ensure_automatic_voice_matching(&self, run: i64) -> Result<Option<Value>> {
        if let Some(job) = self.latest_voice_match_job(run)? {
            return Ok(Some(job));
        }
        if !self.speaker_detection_enabled()? || self.voice_matching_settings()?["enabled"] != true {
            return Ok(None);
        }
        let eligible: bool = self.0.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM model_runs r JOIN meetings m ON m.id=r.meeting_id
                JOIN voice_profiles v JOIN people p ON p.id=v.person_id
                WHERE r.id=?1 AND r.status='completed' AND m.is_demo=0 AND p.is_demo=0
                  AND EXISTS(SELECT 1 FROM speaker_turns WHERE model_run_id=r.id)
                  AND (NOT EXISTS(SELECT 1 FROM meeting_people mp WHERE mp.meeting_id=m.id)
                       OR EXISTS(SELECT 1 FROM meeting_people mp WHERE mp.meeting_id=m.id AND mp.person_id=v.person_id))
                  AND EXISTS(SELECT 1 FROM voice_samples s JOIN voice_consents c ON c.id=s.consent_id
                     WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND c.revoked_at IS NULL))",
            [run], |row| row.get(0),
        )?;
        if eligible {
            self.queue_voice_matching(run)?;
            return self.latest_voice_match_job(run);
        }
        Ok(None)
    }
    pub fn voice_matches(&self, run: i64) -> Result<Value> {
        let job:Option<i64>=self.0.query_row("SELECT id FROM voice_match_jobs WHERE model_run_id=?1 AND state='completed' ORDER BY id DESC LIMIT 1",[run],|r|r.get(0)).optional()?;
        let Some(job) = job else {
            return Ok(json!([]));
        };
        let mut stmt=self.0.prepare(
            "SELECT v.speaker_id,v.status,v.person_id,p.name,v.profile_id,v.similarity,v.reason,v.source_json,
                    j.model_sha256,j.threshold,j.margin
             FROM voice_matches v JOIN voice_match_jobs j ON j.id=v.job_id
             JOIN model_runs r ON r.id=j.model_run_id LEFT JOIN people p ON p.id=v.person_id
             WHERE v.job_id=?1 AND (v.status!='candidate' OR (
                 (NOT EXISTS(SELECT 1 FROM meeting_people mp WHERE mp.meeting_id=r.meeting_id)
                    OR EXISTS(SELECT 1 FROM meeting_people mp WHERE mp.meeting_id=r.meeting_id AND mp.person_id=v.person_id))
                 AND EXISTS(SELECT 1 FROM voice_profiles vp JOIN voice_samples s ON s.person_id=vp.person_id
                            AND s.model_sha256=vp.model_sha256 JOIN voice_consents c ON c.id=s.consent_id
                            WHERE vp.id=v.profile_id AND vp.person_id=v.person_id AND c.revoked_at IS NULL)
             )) ORDER BY v.speaker_id",
        )?;
        let rows:Vec<Value>=stmt.query_map([job],|r|Ok(json!({"job_id":job,"speaker_id":r.get::<_,String>(0)?,"status":r.get::<_,String>(1)?,"person_id":r.get::<_,Option<i64>>(2)?,"person_name":r.get::<_,Option<String>>(3)?,"profile_id":r.get::<_,Option<i64>>(4)?,"similarity":r.get::<_,Option<f64>>(5)?,"reason":r.get::<_,String>(6)?,"source":serde_json::from_str::<Value>(&r.get::<_,String>(7)?).unwrap_or(Value::Null),"model_sha256":r.get::<_,Option<String>>(8)?,"threshold":r.get::<_,f64>(9)?,"margin":r.get::<_,f64>(10)?})))?.collect::<rusqlite::Result<_>>()?;
        Ok(json!(rows))
    }
    pub fn run_voice_matching(&self, id: i64, scratch: &Path, config: &VoiceConfig) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        let busy:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM meetings WHERE status='recording') OR EXISTS(SELECT 1 FROM processing_jobs WHERE status='running') OR EXISTS(SELECT 1 FROM live_chunks WHERE state='running') OR EXISTS(SELECT 1 FROM voice_jobs WHERE state='running') OR EXISTS(SELECT 1 FROM voice_match_jobs WHERE state='running')",[],|r|r.get(0))?;
        if busy {
            bail!("Сопоставление голосов ожидает окончания записи и другой обработки");
        }
        let (run,threshold,margin):(i64,f64,f64)=tx.query_row("SELECT model_run_id,threshold,margin FROM voice_match_jobs WHERE id=?1 AND state='pending'",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
        tx.execute(
            "UPDATE voice_match_jobs SET state='running',error=NULL WHERE id=?1",
            [id],
        )?;
        tx.commit()?;
        let outcome = (|| -> Result<()> {
            let model_hash = checksum(&config.model)?;
            let mut stmt = self.0.prepare(
                "SELECT v.id,v.person_id,v.embedding_json FROM voice_profiles v JOIN people p ON p.id=v.person_id
                 JOIN model_runs r ON r.id=?2
                 WHERE v.model_sha256=?1 AND p.is_demo=0
                   AND (NOT EXISTS(SELECT 1 FROM meeting_people mp WHERE mp.meeting_id=r.meeting_id)
                        OR EXISTS(SELECT 1 FROM meeting_people mp WHERE mp.meeting_id=r.meeting_id AND mp.person_id=v.person_id))
                   AND v.revision=(SELECT max(x.revision) FROM voice_profiles x
                       WHERE x.person_id=v.person_id AND x.model_sha256=v.model_sha256)
                   AND EXISTS(SELECT 1 FROM voice_samples s JOIN voice_consents c ON c.id=s.consent_id
                       WHERE s.person_id=v.person_id AND s.model_sha256=v.model_sha256 AND c.revoked_at IS NULL)",
            )?;
            let profiles: Vec<(i64, i64, String)> = stmt
                .query_map(params![&model_hash,run], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            let mut stmt=self.0.prepare("SELECT speaker_id FROM speaker_turns WHERE model_run_id=?1
                GROUP BY speaker_id ORDER BY SUM(end_ms-start_ms) DESC,speaker_id")?;
            let speakers: Vec<String> = stmt
                .query_map([run], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            let mut results = Vec::new();
            for (index, speaker) in speakers.into_iter().enumerate() {
                let mut result = json!({"speaker_id":speaker,"status":"unknown","person_id":null,"profile_id":null,"similarity":null,"source":null,"reason":"Нет совместимых голосовых профилей"});
                if profiles.is_empty() {
                    results.push(result);
                    continue;
                }
                let plan = match self.voice_source_plan_with_minimum(run, &speaker, 4000) {
                    Ok(plan) => plan,
                    Err(error) => {
                        result["reason"] = json!(error.to_string());
                        results.push(result);
                        continue;
                    }
                };
                result["source"] = plan.clone();
                let dir = scratch.join(format!("speaker-{index}"));
                std::fs::create_dir(&dir)?;
                let wav = dir.join("sample.wav");
                let candidate = (|| -> Result<Vec<f64>> {
                    self.prepare_voice_excerpt(&plan, &wav, &dir, config)?;
                    voice_quality(&wav, 4.0)?;
                    let output = dir.join("vector.json");
                    run_command(
                        Command::new(&config.engine)
                            .arg(&config.model)
                            .arg(&wav)
                            .arg(&output),
                        Duration::from_secs(30),
                    )?;
                    let value: Value = serde_json::from_reader(std::fs::File::open(output)?)?;
                    let values: Vec<f64> = value["embedding"]
                        .as_array()
                        .context("Отсутствует голосовой вектор")?
                        .iter()
                        .map(|v| v.as_f64().context("Некорректный голосовой вектор"))
                        .collect::<Result<_>>()?;
                    normalize(&values)
                })();
                let embedding = match candidate {
                    Ok(v) => v,
                    Err(error) => {
                        result["reason"] = json!(format!("Образец не прошёл проверку: {error}"));
                        results.push(result);
                        continue;
                    }
                };
                let mut scores = Vec::new();
                for (profile, person, raw) in &profiles {
                    let vector: Vec<f64> = serde_json::from_str(raw)?;
                    if vector.len() != embedding.len() {
                        continue;
                    }
                    let vector = normalize(&vector)?;
                    let score = embedding
                        .iter()
                        .zip(vector)
                        .map(|(a, b)| a * b)
                        .sum::<f64>()
                        .clamp(-1.0, 1.0);
                    scores.push((score, *profile, *person));
                }
                scores.sort_by(|a, b| b.0.total_cmp(&a.0));
                if let Some(best) = scores.first() {
                    result["similarity"] = json!(best.0);
                    let separated = scores
                        .get(1)
                        .is_none_or(|second| best.0 - second.0 >= margin);
                    if best.0 >= threshold && separated {
                        result["status"] = json!("candidate");
                        result["person_id"] = json!(best.2);
                        result["profile_id"] = json!(best.1);
                        result["reason"] = json!("Проверьте подсказку и подтвердите имя вручную");
                    } else {
                        result["reason"] = json!(if best.0 < threshold {
                            "Сходство ниже порога: имя не определено"
                        } else {
                            "Похожие голоса: недостаточный отрыв от второго кандидата"
                        });
                    }
                } else {
                    result["reason"] = json!("Нет профилей подходящей размерности");
                }
                results.push(result);
            }
            let tx = self.0.unchecked_transaction()?;
            for result in results {
                tx.execute("INSERT INTO voice_matches(job_id,speaker_id,status,person_id,profile_id,similarity,reason,source_json) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",params![id,result["speaker_id"].as_str(),result["status"].as_str(),result["person_id"].as_i64(),result["profile_id"].as_i64(),result["similarity"].as_f64(),result["reason"].as_str(),result["source"].to_string()])?;
            }
            tx.execute(
                "UPDATE voice_match_jobs SET state='completed',model_sha256=?2 WHERE id=?1",
                params![id, model_hash],
            )?;
            tx.commit()?;
            Ok(())
        })();
        if let Err(error) = outcome {
            self.0.execute(
                "UPDATE voice_match_jobs SET state='failed',error=?2 WHERE id=?1",
                params![id, error.to_string()],
            )?;
            return Err(error);
        }
        Ok(())
    }
}
