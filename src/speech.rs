//! Post-meeting Whisper.cpp CLI backend. Run outside the HTTP/capture process.
use crate::{audio::checksum, Store};
use anyhow::{bail, Context, Result};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(crate) mod blocks;
pub(crate) mod speaker_blocks;
mod worker;
pub use worker::SpeechWorker;

pub struct SpeechConfig {
    pub engine: PathBuf,
    pub model: PathBuf,
    pub ffmpeg: PathBuf,
    pub language: String,
    pub vad_model: Option<PathBuf>,
    pub diarization: Option<crate::diarization::DiarizationConfig>,
}
impl SpeechConfig {
    pub(crate) fn normalize_audio(&self, source: &Path, target: &Path, timeout: Duration) -> Result<()> {
        run_command(
            Command::new(&self.ffmpeg)
                .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
                .arg(source)
                .args(["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-threads", "1"])
                .arg(target),
            timeout,
        )
    }

    pub(crate) fn configure_vad(&self, command: &mut Command) {
        if let Some(model) = &self.vad_model {
            command.arg("--vad").arg("-vm").arg(model).args([
                "-vt", "0.5", "-vspd", "250", "-vsd", "100", "-vp", "30", "-vo", "0.1",
            ]);
        }
    }

    pub fn from_env() -> Result<Self> {
        Self::from_env_with_speaker_detection(true)
    }

    pub fn from_env_with_speaker_detection(enabled: bool) -> Result<Self> {
        Ok(Self {
            engine: resolve(
                &std::env::var_os("VTRACKER_WHISPER_BIN")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| "whisper-cli".into()),
            )?,
            model: std::fs::canonicalize(
                std::env::var_os("VTRACKER_WHISPER_MODEL")
                    .context("set VTRACKER_WHISPER_MODEL to a local multilingual ggml model")?,
            )?,
            ffmpeg: resolve(
                &std::env::var_os("VTRACKER_FFMPEG_BIN")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| "ffmpeg".into()),
            )?,
            diarization: if enabled { crate::diarization::DiarizationConfig::from_env()? } else { None },
            vad_model: std::env::var_os("VTRACKER_VAD_MODEL")
                .map(std::fs::canonicalize)
                .transpose()?,
            language: std::env::var("VTRACKER_LANGUAGE").unwrap_or_else(|_| "ru".into()),
        })
    }
    pub(crate) fn validate(&self) -> Result<()> {
        for path in [&self.engine, &self.model, &self.ffmpeg] {
            if !path.is_file() {
                bail!("required speech file missing: {}", path.display());
            }
        }
        if self.vad_model.as_ref().is_some_and(|p| !p.is_file()) {
            bail!("VAD model file missing");
        }
        if let Some(diarization) = &self.diarization {
            diarization.validate()?;
        }
        if self.language.is_empty()
            || !self
                .language
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b == b'-')
        {
            bail!("invalid language code");
        }
        Ok(())
    }
}
pub fn resolve(path: &Path) -> Result<PathBuf> {
    if path.components().count() > 1 || path.is_absolute() {
        return Ok(std::fs::canonicalize(path)?);
    }
    for dir in std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()) {
        let candidate = dir.join(path);
        if candidate.is_file() {
            return Ok(std::fs::canonicalize(candidate)?);
        }
    }
    bail!("executable not found: {}", path.display())
}
impl Store {
    pub fn speaker_detection_enabled(&self) -> Result<bool> {
        Ok(self.0.query_row(
            "SELECT coalesce((SELECT json_extract(data_json,'$.speaker_detection')
             FROM workspace_settings WHERE key='speech'),1)",
            [], |row| row.get(0),
        )?)
    }

    /// Claim one pending job atomically; failed attempts never overwrite earlier results.
    pub fn run_next(&self, config: &SpeechConfig) -> Result<Option<i64>> {
        self.run_meeting(config, None)
    }
    pub fn run_meeting(
        &self,
        config: &SpeechConfig,
        meeting_filter: Option<i64>,
    ) -> Result<Option<i64>> {
        config.validate()?;
        let cloud = std::env::var_os("VTRACKER_CLOUD_URL").is_some();
        let block_engine = (!cloud).then(blocks::engine).flatten();
        let speaker_threads = speaker_blocks::final_threads();
        let engine_path = block_engine.as_deref().unwrap_or(&config.engine);
        let model_hash = if cloud {
            "remote-model-no-local-checksum".into()
        } else {
            checksum(&config.model)?
        };
        let engine_hash = if cloud {
            "remote-api".into()
        } else {
            checksum(engine_path)?
        };
        let vad_hash = config.vad_model.as_deref().map(checksum).transpose()?;
        let threads = if block_engine.is_some() { 2 } else {
            std::thread::available_parallelism().map_or(1, |n| n.get().min(4))
        };
        let mut parameters = json!({"provider":if cloud {"cloud"} else {"local"},"cloud_model":std::env::var("VTRACKER_CLOUD_MODEL").ok(),"cloud_url":std::env::var("VTRACKER_CLOUD_URL").ok(),"local_model_path":config.model,"threads":threads,"sample_rate":16000,"channels":1,"diarization":config.diarization.as_ref().map(|c|c.parameters()).transpose()?,
            "speaker_detection":self.speaker_detection_enabled()?,
            "max_text_context":(!cloud).then_some(0),
            "vad":config.vad_model.as_ref().filter(|_| !cloud).map(|path|json!({"model_path":path,"sha256":vad_hash,"threshold":0.5,"min_speech_ms":250,"min_silence_ms":100,"pad_ms":30,"overlap_seconds":0.1}))});
        let tx = self.0.unchecked_transaction()?;
        let running: i64 = tx.query_row(
            "SELECT count(*) FROM processing_jobs WHERE status='running'",
            [],
            |r| r.get(0),
        )?;
        let recording: i64 = tx.query_row(
            "SELECT count(*) FROM meetings WHERE status='recording'",
            [],
            |r| r.get(0),
        )?;
        if self.voice_busy()? {
            bail!("Дождитесь завершения обработки голосового профиля");
        }
        if self.live_busy()? {
            bail!("Дождитесь окончания Live-обработки или восстановите прерванную очередь");
        }
        if recording > 0 {
            bail!("stop all recording before post-meeting processing");
        }
        if running > 0 {
            bail!("a worker is already running; recover stale jobs only after checking processes");
        }
        let next = tx.query_row(
            "SELECT id,meeting_id FROM processing_jobs WHERE status='pending' AND (?1 IS NULL OR meeting_id=?1) ORDER BY id LIMIT 1",
            [meeting_filter],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
        );
        let (job, meeting) = match next {
            Ok(next) => next,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        tx.execute("UPDATE processing_jobs SET status='running',attempts=attempts+1,error=NULL,stage='preparing',started_at=unixepoch(),finished_at=NULL WHERE id=?1 AND status='pending'",[job])?;
        tx.commit()?;
        let mut run_id = None;
        let outcome = std::thread::scope(|scope| {
            let preparation_started = Instant::now();
            let mut diarization = config.diarization.clone();
            if let Some(voices) = diarization.as_mut().filter(|voices| voices.speakers == 0) {
                let participants: u32 = self.0.query_row(
                    "SELECT count(*) FROM meeting_people WHERE meeting_id=?1", [meeting], |row| row.get(0),
                )?;
                if (1..=64).contains(&participants) {
                    voices.speakers = participants;
                    parameters["diarization"]["num_speakers"] = json!(participants);
                    parameters["diarization"]["speaker_count_source"] = json!("meeting_participants");
                }
            }
            let speaker_engine = block_engine.as_ref().and_then(|_| speaker_blocks::engine())
                .filter(|_| diarization.as_ref().is_some_and(|voices| voices.speakers == 0));
            let state: String =
                self.0
                    .query_row("SELECT status FROM meetings WHERE id=?1", [meeting], |r| {
                        r.get(0)
                    })?;
            if state == "recording" {
                bail!("post-meeting processing requires recording to stop first");
            }
            let mut inputs = self.speech_inputs(meeting)?;
            if inputs.is_empty() {
                bail!("meeting has no completed audio");
            }
            for input in &inputs {
                let path = Path::new(input["path"].as_str().context("missing audio path")?);
                if checksum(path)? != input["sha256"].as_str().unwrap_or_default() {
                    bail!("source WAV checksum mismatch");
                }
            }
            self.0.execute("INSERT INTO model_runs(job_id,meeting_id,model_path,model_sha256,engine_path,engine_sha256,language,status,inputs_json) VALUES (?1,?2,?3,?4,?5,?6,?7,'running',?8)",rusqlite::params![job,meeting,config.model.to_string_lossy(),model_hash,engine_path.to_string_lossy(),engine_hash,config.language,serde_json::to_string(&inputs)?])?;
            let run = self.0.last_insert_rowid();
            run_id = Some(run);
            self.0.execute(
                "UPDATE model_runs SET parameters_json=?2 WHERE id=?1",
                rusqlite::params![run, parameters.to_string()],
            )?;
            let scratch = tempfile::tempdir()?;
            let wav = scratch.path().join("input.wav");
            normalize_sources(config, &inputs, scratch.path())?;
            let mut merged = hound::WavWriter::create(
                &wav,
                hound::WavSpec {
                    channels: 1,
                    sample_rate: 16000,
                    bits_per_sample: 16,
                    sample_format: hound::SampleFormat::Int,
                },
            )?;
            // Join normalized sources in timeline order, including repeated occurrences.
            let mut total_frames = 0u64;
            for input in &mut inputs {
                let normalized = scratch
                    .path()
                    .join(format!("{}.wav", input["recording_id"].as_i64().unwrap()));
                let mut reader = hound::WavReader::open(normalized)?;
                input["start_ms"] = json!(total_frames * 1000 / 16000);
                input["normalized_frames"] = json!(reader.duration());
                total_frames += reader.duration() as u64;
                input["end_ms"] = json!(total_frames * 1000 / 16000);
                for sample in reader.samples::<i16>() {
                    merged.write_sample(sample?)?;
                }
            }
            merged.finalize()?;
            self.0.execute(
                "UPDATE model_runs SET inputs_json=?2 WHERE id=?1",
                rusqlite::params![run, serde_json::to_string(&inputs)?],
            )?;
            let duration = hound::WavReader::open(&wav)?.duration() as u64 * 1000 / 16000;
            parameters["audio_duration_ms"] = json!(duration);
            let diarization_started = Instant::now();
            let diarization_task = diarization.as_ref().filter(|_| !cloud).map(|config| {
                let config = config.clone();
                let input = wav.clone();
                let scratch = scratch.path().to_path_buf();
                let engine = speaker_engine.clone();
                let database = self.0.path().filter(|path| !path.is_empty()).map(PathBuf::from);
                let sources = inputs.clone();
                let settings = parameters["diarization"].clone();
                scope.spawn(move || -> Result<(Vec<Value>, u64, Option<f64>, bool)> {
                    if let Some(engine) = engine {
                        let database = database.context("Block diarization requires a database file")?;
                        let store = Store::open(&database)?;
                        let turns = speaker_blocks::separate_file(
                            &store, meeting, &config, &engine, &input, &scratch, &sources, speaker_threads,
                        )?;
                        Ok((turns, diarization_started.elapsed().as_millis() as u64, Some(0.2), false))
                    } else {
                        let store = database.as_deref().map(Store::open).transpose()?;
                        let (data, cached) = final_diarization(
                            store.as_ref(), meeting, &settings, &config, &input, &scratch.join("speakers.json"), duration,
                        )?;
                        Ok((crate::diarization::parse_turns(&data, duration)?,
                            diarization_started.elapsed().as_millis() as u64,
                            data["window_shift_ratio"].as_f64(), cached))
                    }
                })
            });
            parameters["parallel_diarization"] = json!(diarization_task.is_some());
            self.speech_stage(job, if diarization_task.is_some() { "transcribing_and_separating" } else { "transcribing" })?;
            let transcription_started = Instant::now();
            let prefix = scratch.path().join("result");
            let mut command = Command::new(&config.engine);
            command
                .arg("-m")
                .arg(&config.model)
                .arg("-f")
                .arg(&wav)
                .arg("-l")
                .arg(&config.language)
                .arg("-t")
                .arg(threads.to_string())
                // Prevent a bad decode from becoming the prompt for subsequent windows.
                .args(["-mc", "0"])
                .arg("-oj")
                .arg("-of")
                .arg(&prefix);
            config.configure_vad(&mut command);
            if cloud {
                let script = scratch.path().join("cloud.py");
                std::fs::write(&script, include_str!("../scripts/cloud-transcribe.py"))?;
                let output = prefix.with_extension("json");
                if run_command(
                    Command::new("python3").arg(&script).arg(&wav).arg(&output),
                    Duration::from_secs(660),
                )
                .is_err()
                {
                    let message = std::fs::read_to_string(format!("{}.error", output.display()))
                        .unwrap_or_else(|_| "Ошибка облачного распознавания".into());
                    bail!("{message}");
                }
            } else if let Some(engine) = &block_engine {
                let (result, cached, processed) =
                    blocks::transcribe_file(self, meeting, config, &wav, scratch.path(), engine, &inputs)?;
                std::fs::write(prefix.with_extension("json"), result.to_string())?;
                parameters["block_processing"] = json!(true);
                parameters["cached_speech_blocks"] = json!(cached);
                parameters["processed_speech_blocks"] = json!(processed);
            } else {
                run_command(&mut command, Duration::from_secs(7200))?;
            }
            let output: Value = serde_json::from_reader(
                std::fs::File::open(prefix.with_extension("json"))
                    .context("Whisper produced no JSON result")?,
            )?;
            let segments = parse_segments(&output, duration, &inputs)?;
            if let Some(timed) = output["cloud_segment_timestamps"].as_bool() {
                parameters["segment_timestamps"] = json!(timed);
            }
            let transcription_finished = Instant::now();
            let separate_voices = diarization.is_some()
                && output["cloud_segment_timestamps"] != false
                && (cloud || config.vad_model.is_none() || !segments.is_empty());
            if separate_voices || diarization_task.as_ref().is_some_and(|task| !task.is_finished()) {
                self.speech_stage(job, "separating")?;
            }
            // Join even for an empty transcript so no model process outlives the job.
            let parallel_result = diarization_task.map(|task| {
                task.join()
                    .map_err(|_| anyhow::anyhow!("diarization worker panicked"))
                    .and_then(|result| result)
            });
            let turns = if let Some(diarization) = diarization
                .as_ref()
                .filter(|_| output["cloud_segment_timestamps"] != false)
                .filter(|_| cloud || config.vad_model.is_none() || !segments.is_empty())
            {
                let (turns, elapsed_ms, ratio, cached) = match parallel_result {
                    Some(result) => result?,
                    None => {
                        let (data, elapsed_ms) = run_diarization(diarization, &wav, &scratch.path().join("speakers.json"))?;
                        (crate::diarization::parse_turns(&data, duration)?, elapsed_ms, data["window_shift_ratio"].as_f64(), false)
                    }
                };
                if let Some(engine) = &speaker_engine {
                    parameters["diarization"]["block_processing"] = json!(true);
                    parameters["diarization"]["threads"] = json!(speaker_threads);
                    parameters["diarization"]["engine_sha256"] = json!(checksum(engine)?);
                }
                if let Some(ratio) = ratio {
                    parameters["diarization"]["window_shift_ratio"] = json!(ratio);
                }
                parameters["diarization_ms"] = json!(elapsed_ms);
                parameters["cached_final_diarization"] = json!(cached);
                turns
            } else {
                Vec::new()
            };
            parameters["preparation_ms"] =
                json!((transcription_started - preparation_started).as_millis());
            parameters["transcription_ms"] =
                json!((transcription_finished - transcription_started).as_millis());
            self.speech_stage(job, "saving")?;
            let tx = self.0.unchecked_transaction()?;
            for turn in turns {
                tx.execute("INSERT INTO speaker_turns(model_run_id,start_ms,end_ms,speaker_id) VALUES (?1,?2,?3,?4)",rusqlite::params![run,turn["start_ms"].as_u64().unwrap(),turn["end_ms"].as_u64().unwrap(),turn["speaker_id"].as_str().unwrap()])?;
            }
            for segment in segments {
                tx.execute("INSERT INTO segments(model_run_id,start_ms,end_ms,text,sources_json) VALUES (?1,?2,?3,?4,?5)",rusqlite::params![run,segment["start_ms"].as_u64().unwrap(),segment["end_ms"].as_u64().unwrap(),segment["text"].as_str().unwrap(),segment["sources"].to_string()])?;
            }
            tx.execute(
                "UPDATE model_runs SET status='completed',parameters_json=?2 WHERE id=?1",
                rusqlite::params![run, parameters.to_string()],
            )?;
            tx.execute(
                "UPDATE processing_jobs SET status='completed',finished_at=unixepoch() WHERE id=?1",
                [job],
            )?;
            tx.commit()?;
            // Identification is optional and never turns a successful transcription into a failure.
            if let Err(error) = self.ensure_automatic_voice_matching(run) {
                let mut updated = parameters.clone();
                updated["voice_matching_error"] = json!(error.to_string());
                let _ = self.0.execute(
                    "UPDATE model_runs SET parameters_json=?2 WHERE id=?1",
                    rusqlite::params![run, updated.to_string()],
                );
            }
            Ok(())
        });
        if let Err(error) = outcome {
            let tx = self.0.unchecked_transaction()?;
            if let Some(run) = run_id {
                tx.execute("UPDATE model_runs SET status='failed' WHERE id=?1", [run])?;
            }
            tx.execute(
                "UPDATE processing_jobs SET status='failed',error=?2,finished_at=unixepoch() WHERE id=?1",
                rusqlite::params![job, error.to_string()],
            )?;
            tx.commit()?;
            return Err(error);
        }
        Ok(Some(job))
    }
    fn speech_stage(&self, job: i64, stage: &str) -> Result<()> {
        self.0.execute(
            "UPDATE processing_jobs SET stage=?2 WHERE id=?1 AND status='running'",
            rusqlite::params![job, stage],
        )?;
        Ok(())
    }
    fn speech_inputs(&self, meeting: i64) -> Result<Vec<Value>> {
        self.audio_inputs(meeting)
    }

    pub fn transcript(&self, meeting: i64) -> Result<Value> {
        self.0
            .query_row("SELECT id FROM meetings WHERE id=?1", [meeting], |r| {
                r.get::<_, i64>(0)
            })
            .context("meeting not found")?;
        let row = self.0.query_row("SELECT id,language,model_sha256,created_at,parameters_json FROM model_runs WHERE meeting_id=?1 AND status='completed' ORDER BY id DESC LIMIT 1",[meeting],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?)));
        let (run, language, model_hash, created, parameters) = match row {
            Ok(row) => row,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(Value::Null),
            Err(error) => return Err(error.into()),
        };
        let mut turns_stmt=self.0.prepare("SELECT start_ms,end_ms,speaker_id FROM speaker_turns WHERE model_run_id=?1 ORDER BY start_ms,id")?;
        let rows=turns_stmt.query_map([run],|r|Ok(json!({"start_ms":r.get::<_,u64>(0)?,"end_ms":r.get::<_,u64>(1)?,"speaker_id":r.get::<_,String>(2)?})))?;
        let mut turns = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        let assignments = self.speaker_assignments(run, false)?;
        let mut matches = self.voice_matches(run)?;
        let parameters: Value = serde_json::from_str(&parameters)?;
        let live_hints = if parameters["speaker_detection"] == false {
            Vec::new()
        } else {
            self.transcript_live_voice_hints(meeting, run)?
        };
        if parameters["diarization"]["num_speakers"] == 0 {
            crate::diarization::suppress_transient_clusters(&mut turns, &assignments);
            if let Some(matches) = matches.as_array_mut() {
                matches.retain(|candidate| {
                    turns
                        .iter()
                        .any(|turn| turn["speaker_id"] == candidate["speaker_id"])
                });
            }
        }
        for turn in &mut turns {
            crate::people::overlay_person(turn, &assignments);
        }
        let reviewed_groups = self.reviewed_speaker_groups(run, &turns)?;
        let automatic_profiles = self.voice_matching_settings()?["enabled"] == true
            && parameters["speaker_detection"] != false;
        let mut stmt = self.0.prepare("SELECT start_ms,end_ms,text,sources_json,id FROM segments WHERE model_run_id=?1 ORDER BY start_ms,id")?;
        let rows = stmt.query_map([run], |r| {
            Ok((
                r.get::<_, u64>(0)?,
                r.get::<_, u64>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, i64>(4)?,
            ))
        })?;
        let mut segments = Vec::new();
        for row in rows {
            let (start, end, text, sources, segment_id) = row?;
            let mut segment = json!({"id":segment_id,"start_ms":start,"end_ms":end,"text":text,"sources":serde_json::from_str::<Value>(&sources)?});
            let assignment = crate::diarization::attribution(start, end, &turns);
            segment
                .as_object_mut()
                .unwrap()
                .extend(assignment.as_object().unwrap().clone());
            crate::people::overlay_person(&mut segment, &assignments);
            for candidate in segment["speaker_candidates"].as_array_mut().unwrap() {
                crate::people::overlay_person(candidate, &assignments);
            }
            self.segment_overlay(run, segment_id, &mut segment)?;
            if segment["overlapping_speakers"].as_array().is_some_and(|ids| !ids.is_empty()) {
                let overlapping: Vec<_> = segment["speaker_candidates"].as_array().unwrap().iter()
                    .filter(|candidate| segment["overlapping_speakers"].as_array().unwrap().contains(&candidate["speaker_id"]))
                    .map(|candidate| {
                        let speaker = candidate["speaker_id"].as_str().unwrap();
                        let profile = matches.as_array().into_iter().flatten()
                            .find(|entry| entry["speaker_id"] == speaker && entry["status"] == "candidate");
                        let (person, name) = if candidate["assignment_source"] == "manual_speaker" {
                            (&candidate["person_id"], &candidate["person_name"])
                        } else if let Some((person, name)) = reviewed_groups.get(speaker) {
                            if profile.is_none_or(|entry| entry["person_id"] == *person) {
                                return json!({"speaker_id":speaker,"person_id":person,"person_name":name});
                            }
                            (&Value::Null, &Value::Null)
                        } else if let Some(profile) = profile {
                            (&profile["person_id"], &profile["person_name"])
                        } else {
                            (&Value::Null, &Value::Null)
                        };
                        json!({"speaker_id":speaker,"person_id":person,"person_name":name})
                    }).collect();
                if let Some(label) = overlap_label(&segment, &overlapping) {
                    segment["overlap_label"] = json!(label);
                }
            }
            if segment["assignment_source"] != "manual_segment"
                && segment["assignment_source"] != "manual_speaker"
            {
                let dominant = crate::diarization::dominant_speaker_candidate(start, end, &segment);
                let profile_match = dominant.filter(|candidate| candidate["assignment_source"] != "manual_speaker")
                    .and_then(|candidate| matches.as_array().and_then(|rows| {
                    rows.iter()
                        .find(|v| v["speaker_id"] == candidate["speaker_id"])
                }));
                let reviewed = dominant
                    .filter(|candidate| candidate["assignment_source"] != "manual_speaker")
                    .and_then(|candidate| candidate["speaker_id"].as_str())
                    .and_then(|speaker| reviewed_groups.get(speaker));
                if let Some((person, name)) = reviewed {
                    if profile_match.is_none_or(|entry| entry["status"] != "candidate" || entry["person_id"] == *person) {
                        segment["person_id"] = json!(person);
                        segment["person_name"] = json!(name);
                        segment["assignment_source"] = json!("auto_reviewed_group");
                    }
                } else if let Some(candidate) = profile_match {
                    if automatic_profiles && candidate["status"] == "candidate" {
                        segment["person_id"] = candidate["person_id"].clone();
                        segment["person_name"] = candidate["person_name"].clone();
                        segment["assignment_source"] = json!("auto_profile");
                    } else {
                        segment["voice_suggestion"] = candidate.clone();
                    }
                }
                if automatic_profiles && reviewed.is_none() && segment["person_id"].is_null() {
                    if let Some(identity) = crate::live_voice::suggestion_for_segment(
                        start, end, &[], &turns,
                        segment["speaker_candidates"].as_array().unwrap(),
                        matches.as_array().map_or(&[], Vec::as_slice),
                    ) {
                        segment["person_id"] = identity["person_id"].clone();
                        segment["person_name"] = identity["person_name"].clone();
                        segment["assignment_source"] = json!("auto_profile");
                        segment["voice_suggestion"] = Value::Null;
                    }
                }
                if reviewed.is_none() && segment["person_id"].is_null() && segment["voice_suggestion"]["status"] != "candidate" {
                    if let Some(suggestion) = crate::live_voice::suggestion_for_segment(
                        start, end, &live_hints, &turns,
                        segment["speaker_candidates"].as_array().unwrap(),
                        matches.as_array().map_or(&[], Vec::as_slice),
                    ) {
                        segment["voice_suggestion"] = suggestion;
                    }
                }
            }
            segments.push(segment);
        }
        Ok(
            json!({"meeting_id":meeting,"model_run_id":run,"voice_matches":matches,"speaker_assignments":assignments,"language":language,"model_sha256":model_hash,"created_at":created,"status":"final","speaker_turns":turns,"parameters":parameters,"segments":segments}),
        )
    }
    pub fn recover_job(&self, job: i64) -> Result<()> {
        let tx = self.0.unchecked_transaction()?;
        if tx.execute("UPDATE processing_jobs SET status='failed',error='worker interrupted (operator recovery)',finished_at=unixepoch() WHERE id=?1 AND status='running'",[job])? != 1 { bail!("job is not running"); }
        tx.execute(
            "UPDATE model_runs SET status='failed' WHERE job_id=?1 AND status='running'",
            [job],
        )?;
        tx.commit()?;
        Ok(())
    }
}
fn overlap_label(segment: &Value, voices: &[Value]) -> Option<String> {
    if segment["assignment_source"] == "manual_segment" && segment["person_id"].is_null() {
        return None;
    }
    let mut names = std::collections::BTreeMap::new();
    let mut unknown = 0;
    for voice in voices {
        if let (Some(id), Some(name)) = (voice["person_id"].as_i64(), voice["person_name"].as_str()) {
            names.insert(id, name);
        } else {
            unknown += 1;
        }
    }
    if let (Some(id), Some(name)) = (segment["person_id"].as_i64(), segment["person_name"].as_str()) {
        if !names.contains_key(&id) {
            if unknown == 0 { return None; }
            names.insert(id, name);
            unknown -= 1;
        }
    }
    if names.is_empty() {
        return Some("Голоса пересекаются".into());
    }
    if names.len() == 1 && unknown == 0 { return None; }
    let mut labels: Vec<_> = names.into_values().collect();
    if unknown > 0 { labels.push(if unknown == 1 { "неопознанный голос" } else { "неопознанные голоса" }); }
    Some(format!("{} · одновременно", labels.join(" и ")))
}
fn normalize_sources(config: &SpeechConfig, inputs: &[Value], scratch: &Path) -> Result<()> {
    let mut unique = std::collections::BTreeMap::new();
    for input in inputs {
        let id = input["recording_id"].as_i64().context("missing recording id")?;
        let source = Path::new(input["path"].as_str().context("missing audio path")?);
        unique.entry(id).or_insert(source);
    }
    let sources: Vec<_> = unique.into_iter().collect();
    let workers = std::thread::available_parallelism().map_or(1, |count| count.get().min(3));
    let batch_size = sources.len().div_ceil(workers).max(1);
    std::thread::scope(|scope| {
        let jobs = sources.chunks(batch_size).map(|batch| {
            scope.spawn(move || -> Result<()> {
                for (id, path) in batch {
                    config.normalize_audio(path, &scratch.join(format!("{id}.wav")), Duration::from_secs(300))?;
                }
                Ok(())
            })
        }).collect::<Vec<_>>();
        for job in jobs {
            job.join().map_err(|_| anyhow::anyhow!("audio normalization worker panicked"))??;
        }
        Ok(())
    })
}

fn final_diarization(
    store: Option<&Store>,
    meeting: i64,
    settings: &Value,
    config: &crate::diarization::DiarizationConfig,
    input: &Path,
    output: &Path,
    duration: u64,
) -> Result<(Value, bool)> {
    let Some(store) = store else {
        return Ok((run_diarization(config, input, output)?.0, false));
    };
    // Whole-meeting output is compatible only with identical normalized audio,
    // models, engine and clustering settings. Live blocks use a different key.
    let fingerprint = json!({"kind":"whole-meeting-v1","audio_sha256":checksum(input)?,"configuration":settings});
    let key = format!("{:x}", Sha256::digest(fingerprint.to_string().as_bytes()));
    let cached: Option<String> = store.0.query_row(
        "SELECT result_json FROM speaker_blocks WHERE meeting_id=?1 AND cache_key=?2",
        rusqlite::params![meeting,key], |row| row.get(0),
    ).optional()?;
    if let Some(data) = cached.as_deref().and_then(|raw| serde_json::from_str::<Value>(raw).ok()) {
        if crate::diarization::parse_turns(&data, duration).is_ok() {
            return Ok((data, true));
        }
    }
    let (data, _) = run_diarization(config, input, output)?;
    crate::diarization::parse_turns(&data, duration)?;
    store.0.execute(
        "INSERT INTO speaker_blocks(meeting_id,cache_key,result_json) VALUES (?1,?2,?3)
         ON CONFLICT(meeting_id,cache_key) DO UPDATE SET result_json=excluded.result_json",
        rusqlite::params![meeting,key,data.to_string()],
    )?;
    Ok((data, false))
}

fn run_diarization(
    config: &crate::diarization::DiarizationConfig,
    input: &Path,
    output: &Path,
) -> Result<(Value, u64)> {
    let started = Instant::now();
    let mut command = Command::new(&config.engine);
    command.arg(&config.segmentation).arg(&config.embedding)
        .arg(input).arg(output).arg(config.speakers.to_string());
    if let Some(threshold) = config.cluster_threshold {
        command.arg(threshold.to_string());
    }
    run_command(&mut command, Duration::from_secs(7200))?;
    let data = serde_json::from_reader(
        std::fs::File::open(output).context("diarization produced no result")?,
    )?;
    Ok((data, started.elapsed().as_millis() as u64))
}

pub(crate) fn run_command(command: &mut Command, timeout: Duration) -> Result<()> {
    let tool = command.get_program().to_string_lossy().into_owned();
    let mut child = command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
        .context("cannot launch speech tool")?;
    let start = Instant::now();
    loop {
        if let Some(exit) = child.try_wait()? {
            if !exit.success() {
                bail!(
                    "{tool} exited with {exit}; check engine/model compatibility and input format"
                );
            }
            return Ok(());
        }
        let elapsed = start.elapsed();
        if elapsed >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{tool} timed out");
        }
        // Audio normalization launches many short-lived processes for long meetings.
        let interval = if elapsed < Duration::from_millis(100) { 10 } else { 100 };
        std::thread::sleep(Duration::from_millis(interval).min(timeout - elapsed));
    }
}
pub(crate) fn parse_segments(
    output: &Value,
    duration: u64,
    inputs: &[Value],
) -> Result<Vec<Value>> {
    let rows = output["transcription"]
        .as_array()
        .context("Whisper JSON missing transcription array")?;
    let mut segments = Vec::new();
    for row in rows {
        let text = row["text"].as_str().context("segment text missing")?.trim();
        if text.is_empty() { continue; }
        let start = row["offsets"]["from"]
            .as_u64()
            .context("segment start offset missing")?;
        let end = row["offsets"]["to"]
            .as_u64()
            .context("segment end offset missing")?;
        if end < start || end > duration.saturating_add(1000) {
            bail!("Некорректные таймкоды Whisper: {start}–{end} мс при длительности {duration} мс");
        }
        let end = end.min(duration);
        if start >= end {
            // Whisper occasionally emits zero-length rows or a row just past the audio boundary.
            continue;
        }
        let sources: Vec<_> = inputs
            .iter()
            .filter(|v| {
                v["start_ms"].as_u64().unwrap() < end && v["end_ms"].as_u64().unwrap() > start
            })
            .cloned()
            .collect();
        segments.push(json!({"start_ms":start,"end_ms":end,"text":text,"sources":sources}));
    }
    Ok(segments)
}

pub fn transcript_text(transcript: &Value) -> String {
    let Some(segments) = transcript["segments"].as_array() else {
        return "Transcript: unavailable".into();
    };
    if segments.is_empty() {
        return "Transcript: no speech segments".into();
    }
    segments
        .iter()
        .map(|s| {
            format!(
                "[{}–{} ms] [{}] {}",
                s["start_ms"],
                s["end_ms"],
                s["person_name"]
                    .as_str()
                    .or_else(|| s["speaker_id"].as_str())
                    .unwrap_or(if s["speaker_status"] == "multiple" {
                        "multiple"
                    } else {
                        "unknown"
                    }),
                s["text"].as_str().unwrap_or_default()
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}
