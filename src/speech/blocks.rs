//! Reusable speech blocks. The key includes audio and every inference setting.
use super::{parse_segments, SpeechConfig};
use crate::{audio::checksum, Store};
use anyhow::{bail, Context, Result};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

pub(crate) struct ModelProcess {
    child: Child,
    input: ChildStdin,
    responses: Receiver<std::io::Result<String>>,
}

impl ModelProcess {
    pub(crate) fn start(command: &mut Command) -> Result<Self> {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let input = child.stdin.take().context("missing model input")?;
        let output = child.stdout.take().context("missing model output")?;
        let (sender, responses) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            input,
            responses,
        })
    }

    pub(crate) fn request(&mut self, request: Value) -> Result<Value> {
        writeln!(self.input, "{request}")?;
        self.input.flush()?;
        let line = self
            .responses
            .recv_timeout(Duration::from_secs(120))
            .context("Model block timed out or worker stopped")??;
        let output: Value = serde_json::from_str(&line)?;
        if let Some(error) = output["error"].as_str() {
            bail!("{error}");
        }
        Ok(output)
    }
}

impl Drop for ModelProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub(crate) struct WhisperSession {
    process: Option<ModelProcess>,
    command: Command,
    fingerprint: String,
    pub(crate) model_hash: String,
    pub(crate) engine_hash: String,
}
impl WhisperSession {
    pub(crate) fn start(config: &SpeechConfig, engine: &Path) -> Result<Self> {
        let model_hash = checksum(&config.model)?;
        let engine_hash = checksum(engine)?;
        let fingerprint = json!({
            "revision":1, "engine":engine_hash, "model":model_hash,
            "language":config.language, "vad":config.vad_model.as_deref().map(checksum).transpose()?,
            "threads":2,"beam":5,"context":0
        }).to_string();
        let mut command = Command::new(engine);
        command
            .arg(&config.model)
            .arg(&config.language)
            .arg(config.vad_model.as_deref().unwrap_or(Path::new("")));
        Ok(Self {
            process: None,
            command,
            fingerprint,
            model_hash,
            engine_hash,
        })
    }

    pub(crate) fn transcribe(
        &mut self,
        store: &Store,
        meeting: i64,
        samples: &[i16],
        scratch: &Path,
    ) -> Result<Value> {
        let mut hash = Sha256::new();
        hash.update(self.fingerprint.as_bytes());
        for sample in samples {
            hash.update(sample.to_le_bytes());
        }
        let key = format!("{:x}", hash.finalize());
        let cached: Option<String> = store
            .0
            .query_row(
                "SELECT result_json FROM speech_blocks WHERE meeting_id=?1 AND cache_key=?2",
                rusqlite::params![meeting, key],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(cached) = cached {
            return Ok(serde_json::from_str(&cached)?);
        }
        let pcm = scratch.join("block.pcm");
        let mut file = std::io::BufWriter::new(std::fs::File::create(&pcm)?);
        for sample in samples {
            file.write_all(&(*sample as f32 / 32768.0).to_le_bytes())?;
        }
        file.flush()?;
        let began = Instant::now();
        if self.process.is_none() {
            self.process = Some(ModelProcess::start(&mut self.command)?);
        }
        let output = self.process.as_mut().unwrap().request(json!({"pcm":pcm}))?;
        let duration = samples.len() as u64 * 1000 / 16000;
        parse_segments(&output, duration, &[])?;
        store.0.execute(
            "INSERT OR IGNORE INTO speech_blocks(meeting_id,cache_key,result_json,duration_ms,elapsed_ms) VALUES (?1,?2,?3,?4,?5)",
            rusqlite::params![meeting,key,output.to_string(),duration,began.elapsed().as_millis() as u64],
        )?;
        Ok(output)
    }
}
pub(crate) fn engine() -> Option<PathBuf> {
    std::env::var_os("VTRACKER_WHISPER_WORKER")
        .map(PathBuf::from)
        .filter(|p| p.is_file())
}

// Keep capture sessions independent so continuing a meeting can reuse their blocks.
pub(crate) fn capture_block_len(inputs: &[Value]) -> usize {
    let Some(first) = inputs.first() else {
        return 0;
    };
    if first["session_id"].is_null() {
        return 1;
    }
    let mut duration = 0.0;
    let mut count = 0;
    for input in inputs
        .iter()
        .take_while(|input| input["session_id"] == first["session_id"])
    {
        count += 1;
        duration += input["frames"].as_u64().unwrap_or(0) as f64
            / input["sample_rate"].as_u64().unwrap_or(16000) as f64;
        if duration >= 29.99 {
            break;
        }
    }
    count
}

impl WhisperSession {
    pub(crate) fn transcribe_group(
        &mut self,
        store: &Store,
        meeting: i64,
        samples: &[i16],
        scratch: &Path,
        offset_ms: u64,
    ) -> Result<Vec<Value>> {
        let mut cursor = 0;
        let mut rows = Vec::new();
        while cursor < samples.len() {
            let remaining = &samples[cursor..];
            let size = if remaining.len() <= 35 * 16000 {
                remaining.len()
            } else {
                30 * 16000
            };
            let result = self.transcribe(store, meeting, &remaining[..size], scratch)?;
            let shift = offset_ms + cursor as u64 * 1000 / 16000;
            for segment in parse_segments(&result, size as u64 * 1000 / 16000, &[])? {
                rows.push(json!({
                    "text":segment["text"],
                    "offsets":{
                        "from":segment["start_ms"].as_u64().unwrap() + shift,
                        "to":segment["end_ms"].as_u64().unwrap() + shift,
                    },
                }));
            }
            cursor += size;
        }
        Ok(rows)
    }
}

pub(crate) fn transcribe_file(
    store: &Store,
    meeting: i64,
    config: &SpeechConfig,
    input: &Path,
    scratch: &Path,
    engine: &Path,
    inputs: &[Value],
) -> Result<Value> {
    let mut session = WhisperSession::start(config, engine)?;
    let mut reader = hound::WavReader::open(input)?;
    let mut samples = reader.samples::<i16>();
    let mut offset = 0u64;
    let mut rows = Vec::new();
    let mut pending = inputs;
    while !pending.is_empty() {
        let count = capture_block_len(pending);
        let frames = pending[..count]
            .iter()
            .map(|source| {
                source["normalized_frames"]
                    .as_u64()
                    .context("missing normalized frame count")
            })
            .sum::<Result<u64>>()? as usize;
        // Imports can be long. Keep the working buffer bounded.
        let mut remaining = frames;
        while remaining > 0 {
            let size = if remaining <= 35 * 16000 {
                remaining
            } else {
                30 * 16000
            };
            let block = samples
                .by_ref()
                .take(size)
                .collect::<std::result::Result<Vec<_>, _>>()?;
            if block.len() != size {
                bail!("truncated normalized audio");
            }
            rows.extend(session.transcribe_group(
                store,
                meeting,
                &block,
                scratch,
                offset * 1000 / 16000,
            )?);
            offset += size as u64;
            remaining -= size;
        }
        pending = &pending[count..];
    }
    Ok(json!({"transcription":rows}))
}
