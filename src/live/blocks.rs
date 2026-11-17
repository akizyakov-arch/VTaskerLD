use crate::{
    audio::checksum,
    speech::{
        blocks::{self, WhisperSession},
        parse_segments,
        speaker_blocks::{self, MeetingVoices, SpeakerSession, GROUPS_PER_BLOCK},
        SpeechConfig,
    },
    Store,
};
use anyhow::{bail, Context, Result};
use rusqlite::{params, OptionalExtension, Transaction, TransactionBehavior};
use serde_json::{json, Value};
use std::{
    path::Path,
    time::{Duration, Instant},
};

impl Store {
    pub fn run_live_blocks(
        &self,
        session: &str,
        mut config: SpeechConfig,
        scratch: &Path,
    ) -> Result<()> {
        let (meeting, model, language): (i64, String, String) = self.0.query_row(
            "SELECT meeting_id,model_path,language FROM live_sessions WHERE session_id=?1 AND state='active'",
            [session], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
        config.model = model.into();
        config.language = language;
        config.validate()?;
        let engine = blocks::engine().context("Постоянный обработчик Whisper недоступен")?;
        let mut whisper = None;
        let mut speaker = config
            .diarization
            .as_ref()
            .filter(|config| config.speakers == 0)
            .zip(speaker_blocks::engine())
            .map(|(config, engine)| SpeakerSession::new(config, &engine))
            .transpose()?;
        let mut voices = MeetingVoices::default();
        if let Some(speaker) = &speaker {
            let previous: Option<String> = self.0.query_row(
                "SELECT speaker_profiles_json FROM live_sessions WHERE meeting_id=?1 AND session_id<>?2
                 AND speaker_profiles_json IS NOT NULL ORDER BY rowid DESC LIMIT 1",
                params![meeting, session], |row| row.get(0),
            ).optional()?;
            if let Some(previous) = previous {
                let snapshot: Value = serde_json::from_str(&previous)?;
                if snapshot["fingerprint"] == speaker.fingerprint {
                    voices = MeetingVoices::from_snapshot(&snapshot)?;
                }
            }
        }
        let mut speaker_samples = Vec::new();
        let mut speaker_offset = 0;
        let mut speaker_groups = 0;
        let mut speaker_turns = Vec::new();
        loop {
            let active: bool = self.0.query_row(
                "SELECT state='active' FROM live_sessions WHERE session_id=?1",
                [session],
                |row| row.get(0),
            )?;
            if !active {
                return Ok(());
            }
            let stopping = scratch.join("finish").is_file();
            let mut next: u64 = self.0.query_row(
                "SELECT coalesce(max(coalesce(last_sequence,sequence))+1,0)
                 FROM live_chunks WHERE session_id=?1 AND state='completed'",
                [session],
                |row| row.get(0),
            )?;
            let mut inputs = self
                .audio_inputs(meeting)?
                .into_iter()
                .filter(|source| {
                    source["session_id"] == session
                        && source["sequence"]
                            .as_u64()
                            .is_some_and(|sequence| sequence >= next)
                })
                .collect::<Vec<_>>();
            let backlog_ms = inputs
                .last()
                .and_then(|last| last["end_ms"].as_u64())
                .zip(inputs.first().and_then(|first| first["start_ms"].as_u64()))
                .map_or(0, |(end, start)| end.saturating_sub(start));
            if !stopping && backlog_ms > 4 * 30_000 {
                self.defer_live(
                    session,
                    "Live не успевает за записью. Оставшееся аудио обработается после встречи",
                )?;
                return Ok(());
            }

            while !inputs.is_empty() {
                let count = blocks::capture_block_len(&inputs);
                let first = &inputs[0];
                let last = &inputs[count - 1];
                let start = first["start_ms"].as_u64().context("missing block start")?;
                let end = last["end_ms"].as_u64().context("missing block end")?;
                let last_sequence = last["sequence"]
                    .as_u64()
                    .context("missing block sequence")?;
                if !stopping && end.saturating_sub(start) < 29990 {
                    break;
                }
                let tx = Transaction::new_unchecked(&self.0, TransactionBehavior::Immediate)?;
                if self.voice_busy()? || self.live_busy()? {
                    break;
                }
                let final_busy: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM processing_jobs WHERE status='running')",
                    [],
                    |row| row.get(0),
                )?;
                if final_busy {
                    break;
                }
                tx.execute(
                    "INSERT INTO live_chunks(session_id,sequence,last_sequence,recording_id,start_ms,end_ms,state)
                     VALUES (?1,?2,?3,?4,?5,?6,'running')
                     ON CONFLICT(session_id,sequence) DO UPDATE SET state='running',error=NULL,last_sequence=excluded.last_sequence,end_ms=excluded.end_ms",
                    params![session,next,last_sequence,first["recording_id"].as_i64(),start,end],
                )?;
                tx.commit()?;
                let began = Instant::now();
                let result = (|| -> Result<()> {
                    if whisper.is_none() {
                        whisper = Some(WhisperSession::start(&config, &engine)?);
                    }
                    let worker = whisper.as_mut().unwrap();
                    let mut samples = Vec::new();
                    let normalized = scratch.join("normalized.wav");
                    for source in &mut inputs[..count] {
                        let path =
                            Path::new(source["path"].as_str().context("missing audio path")?);
                        if checksum(path)?
                            != source["sha256"].as_str().context("missing checksum")?
                        {
                            bail!("Повреждён сохранённый WAV-фрагмент");
                        }
                        config.normalize_audio(path, &normalized, Duration::from_secs(10))?;
                        let mut reader = hound::WavReader::open(&normalized)?;
                        let offset = samples.len() as u64 * 1000 / 16000;
                        source["start_ms"] = json!(offset);
                        for sample in reader.samples::<i16>() {
                            samples.push(sample?);
                        }
                        source["end_ms"] = json!(samples.len() as u64 * 1000 / 16000);
                        std::fs::remove_file(&normalized)?;
                    }
                    let duration = samples.len() as u64 * 1000 / 16000;
                    let output = json!({"transcription":worker.transcribe_group(self, meeting, &samples, scratch, 0)?});
                    let mut segments = parse_segments(&output, duration, &inputs[..count])?;
                    for segment in &mut segments {
                        for key in ["start_ms", "end_ms"] {
                            segment[key] = json!(segment[key].as_u64().unwrap() + start);
                        }
                        segment["status"] = json!("preliminary");
                        for source in segment["sources"].as_array_mut().unwrap() {
                            for key in ["start_ms", "end_ms"] {
                                source[key] = json!(source[key].as_u64().unwrap() + start);
                            }
                        }
                    }
                    if let Some(speaker) = speaker.as_mut() {
                        if speaker_samples.is_empty() {
                            speaker_offset = start;
                        }
                        speaker_samples.extend(samples);
                        speaker_groups += 1;
                        if speaker_groups == GROUPS_PER_BLOCK || (stopping && count == inputs.len())
                        {
                            speaker_turns.extend(speaker.separate_group(
                                self,
                                meeting,
                                &speaker_samples,
                                scratch,
                                speaker_offset,
                                &mut voices,
                            )?);
                            speaker_samples.clear();
                            speaker_groups = 0;
                            self.publish_live_speakers(
                                session,
                                &speaker_turns,
                                &voices.snapshot(&speaker.fingerprint),
                            )?;
                        }
                    }
                    self.0.execute(
                        "UPDATE live_chunks SET state='completed',result_json=?3,model_sha256=?4,engine_sha256=?5,elapsed_ms=?6
                         WHERE session_id=?1 AND sequence=?2 AND state='running'",
                        params![session,next,json!(segments).to_string(),worker.model_hash,worker.engine_hash,began.elapsed().as_millis() as u64],
                    )?;
                    Ok(())
                })();
                if let Err(error) = result {
                    self.0.execute(
                        "UPDATE live_chunks SET state='failed',error=?3 WHERE session_id=?1 AND sequence=?2 AND state='running'",
                        params![session,next,error.to_string()],
                    )?;
                    self.defer_live(
                        session,
                        "Live остановлен из-за ошибки; сохранённое аудио доступно для обработки",
                    )?;
                    return Err(error);
                }
                next = last_sequence + 1;
                inputs.drain(..count);
            }
            if stopping && inputs.is_empty() {
                if let Some(speaker) = speaker.as_mut().filter(|_| !speaker_samples.is_empty()) {
                    speaker_turns.extend(speaker.separate_group(
                        self,
                        meeting,
                        &speaker_samples,
                        scratch,
                        speaker_offset,
                        &mut voices,
                    )?);
                    self.publish_live_speakers(
                        session,
                        &speaker_turns,
                        &voices.snapshot(&speaker.fingerprint),
                    )?;
                }
                self.finish_live(session)?;
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    }
    fn publish_live_speakers(
        &self,
        session: &str,
        turns: &[Value],
        profiles: &Value,
    ) -> Result<()> {
        self.0.execute(
            "UPDATE live_sessions SET speaker_turns_json=?2,speaker_profiles_json=?3 WHERE session_id=?1",
            params![session,json!(turns).to_string(),profiles.to_string()],
        )?;
        Ok(())
    }
}
