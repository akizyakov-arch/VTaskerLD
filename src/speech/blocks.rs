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
    tail: Vec<i16>,
    tail_text: String,
    window_end_ms: Option<u64>,
    cached_blocks: usize,
    processed_blocks: usize,
}

pub(crate) const OVERLAP_FRAMES: usize = 16000;

pub(crate) fn trim_overlap_text(previous: &str, text: &str) -> String {
    fn key(word: &str) -> String {
        word.trim_matches(|ch: char| !ch.is_alphanumeric()).to_lowercase().replace('ё', "е")
    }
    let before: Vec<_> = previous.split_whitespace().map(key).collect();
    let words: Vec<_> = text.split_whitespace().collect();
    let after: Vec<_> = words.iter().map(|word| key(word)).collect();
    let shared = (1..=before.len().min(after.len()).min(12)).rev().find(|&n| {
        let suffix = &before[before.len()-n..];
        (n > 1 || suffix[0].chars().count() >= 4)
            && !suffix.iter().any(String::is_empty) && suffix == &after[..n]
    });
    shared.map_or_else(|| text.to_owned(), |n| words[n..].join(" "))
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
            tail: Vec::new(),
            tail_text: String::new(),
            window_end_ms: None,
            cached_blocks: 0,
            processed_blocks: 0,
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
            self.cached_blocks += 1;
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
        self.processed_blocks += 1;
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
    fn clear_context(&mut self) {
        self.tail.clear();
        self.tail_text.clear();
        self.window_end_ms = None;
    }

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
            let shift = offset_ms + cursor as u64 * 1000 / 16000;
            if !self.window_end_ms.is_some_and(|end| end.abs_diff(shift) <= 2) {
                self.clear_context();
            }
            let block = &remaining[..size];
            let prefix_ms = self.tail.len() as u64 * 1000 / 16000;
            let window_start = shift.saturating_sub(prefix_ms);
            let mut window = Vec::with_capacity(self.tail.len() + size);
            window.extend_from_slice(&self.tail);
            window.extend_from_slice(block);
            let result = self.transcribe(store, meeting, &window, scratch)?;
            let end = shift + size as u64 * 1000 / 16000;
            let first_row = rows.len();
            for segment in parse_segments(&result, window.len() as u64 * 1000 / 16000, &[])? {
                let from = window_start + segment["start_ms"].as_u64().unwrap();
                let to = (window_start + segment["end_ms"].as_u64().unwrap()).min(end);
                if to <= shift { continue; }
                let recognized = segment["text"].as_str().unwrap_or_default();
                let text = if from < shift {
                    let trimmed = trim_overlap_text(&self.tail_text, recognized);
                    if trimmed.is_empty() && to.saturating_sub(shift) > 550 {
                        recognized.to_owned()
                    } else { trimmed }
                } else { recognized.to_owned() };
                if text.trim().is_empty() { continue; }
                rows.push(json!({
                    "text":text,"offsets":{"from":from.max(shift),"to":to},
                }));
            }
            self.tail_text = rows[first_row..].iter()
                .filter(|row| row["offsets"]["to"].as_u64().is_some_and(|to| to > end.saturating_sub(1000)))
                .filter_map(|row| row["text"].as_str()).collect::<Vec<_>>().join(" ");
            self.tail.clear();
            self.tail.extend_from_slice(&block[block.len().saturating_sub(OVERLAP_FRAMES)..]);
            self.window_end_ms = Some(end);
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
) -> Result<(Value, usize, usize)> {
    let mut session = WhisperSession::start(config, engine)?;
    let mut reader = hound::WavReader::open(input)?;
    let mut samples = reader.samples::<i16>();
    let mut offset = 0u64;
    let mut rows = Vec::new();
    let mut pending = inputs;
    let mut previous_session = Value::Null;
    while !pending.is_empty() {
        if pending[0]["session_id"].is_null() || pending[0]["session_id"] != previous_session {
            session.clear_context();
        }
        previous_session = pending[0]["session_id"].clone();
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
    Ok((json!({"transcription":rows}), session.cached_blocks, session.processed_blocks))
}

#[cfg(test)]
mod tests {
    use super::trim_overlap_text;

    #[test]
    fn audio_prefix_removes_only_the_matching_words_at_the_boundary() {
        assert_eq!(trim_overlap_text("Мы закупим ткань для", "Ткань для штор и скатертей"),"штор и скатертей");
        assert_eq!(trim_overlap_text("Срок в пятницу.", "Пятницу, как договорились."),"как договорились.");
        assert_eq!(trim_overlap_text("Ткань уже закупили", "Закупку перенесём на завтра"),"Закупку перенесём на завтра");
        assert_eq!(trim_overlap_text("Согласуем и", "И начнём работу"),"И начнём работу");
    }

    #[cfg(unix)]
    #[test]
    fn contiguous_decoder_windows_include_audio_context_and_keep_one_copy_of_the_boundary() {
        use super::{json, SpeechConfig, Store, WhisperSession};
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let model = dir.path().join("model");
        let engine = dir.path().join("whisper");
        std::fs::write(&model, b"fixture").unwrap();
        std::fs::write(&engine, r#"#!/usr/bin/env python3
import json, sys
from pathlib import Path
for line in sys.stdin:
    frames = Path(json.loads(line)['pcm']).stat().st_size // 4
    if frames == 32000:
        rows = [{'text':'Проверим ткань для','offsets':{'from':0,'to':2000}}]
    elif frames == 48000:
        rows = [
            {'text':'Перед стыком','offsets':{'from':0,'to':500}},
            {'text':'Ткань для штор','offsets':{'from':500,'to':2500}},
        ]
    else:
        raise ValueError(frames)
    print(json.dumps({'transcription':rows},ensure_ascii=False),flush=True)
"#).unwrap();
        std::fs::set_permissions(&engine,std::fs::Permissions::from_mode(0o700)).unwrap();
        let store = Store::open(&dir.path().join("db")).unwrap();
        let meeting = store.create_meeting("Стык блоков").unwrap();
        let config = SpeechConfig {
            engine:engine.clone(),model,ffmpeg:"ffmpeg".into(),language:"ru".into(),vad_model:None,diarization:None,
        };
        let mut session = WhisperSession::start(&config,&engine).unwrap();
        assert_eq!(session.transcribe_group(&store,meeting,&[1;32000],dir.path(),0).unwrap()[0]["text"],"Проверим ткань для");
        let rows = session.transcribe_group(&store,meeting,&[2;32000],dir.path(),2000).unwrap();
        assert_eq!(rows,vec![json!({"text":"штор","offsets":{"from":2000,"to":3500}})]);
        let rows = session.transcribe_group(&store,meeting,&[2;32000],dir.path(),5000).unwrap();
        assert_eq!(rows[0]["text"],"Проверим ткань для");
    }
}
