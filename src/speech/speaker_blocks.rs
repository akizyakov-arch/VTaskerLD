//! Separate voices in bounded blocks and compare them across the meeting.
use super::blocks::{capture_block_len, ModelProcess};
use crate::{
    audio::checksum,
    diarization::{parse_turns, DiarizationConfig},
    voice::normalize,
    Store,
};
use anyhow::{bail, Context, Result};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    process::Command,
};

pub(crate) const GROUPS_PER_BLOCK: usize = 4;
const MAX_BLOCK_FRAMES: usize = 120 * 16000;

pub(crate) fn engine() -> Option<PathBuf> {
    std::env::var_os("VTRACKER_SPEAKER_WORKER")
        .map(PathBuf::from)
        .filter(|p| p.is_file())
}

pub(crate) struct SpeakerSession {
    pub(crate) fingerprint: String,
    command: Command,
    process: Option<ModelProcess>,
}

impl SpeakerSession {
    pub(crate) fn new(config: &DiarizationConfig, engine: &Path) -> Result<Self> {
        let threshold = config.cluster_threshold.unwrap_or(0.5);
        let fingerprint = json!({
            "revision":1, "worker":checksum(engine)?,
            "segmentation":checksum(&config.segmentation)?, "embedding":checksum(&config.embedding)?,
            "threshold":threshold,
        }).to_string();
        let mut command = Command::new(engine);
        command
            .arg(&config.segmentation)
            .arg(&config.embedding)
            .arg(threshold.to_string());
        Ok(Self {
            fingerprint,
            command,
            process: None,
        })
    }

    pub(crate) fn separate(
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
                "SELECT result_json FROM speaker_blocks WHERE meeting_id=?1 AND cache_key=?2",
                rusqlite::params![meeting, key],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(cached) = cached {
            return Ok(serde_json::from_str(&cached)?);
        }

        let path = scratch.join("speaker-block.wav");
        let mut writer = hound::WavWriter::create(
            &path,
            hound::WavSpec {
                channels: 1,
                sample_rate: 16000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )?;
        for sample in samples {
            writer.write_sample(*sample)?;
        }
        writer.finalize()?;
        if self.process.is_none() {
            self.process = Some(ModelProcess::start(&mut self.command)?);
        }
        let output = self
            .process
            .as_mut()
            .unwrap()
            .request(json!({"wav":path}))?;
        parse_turns(&output, samples.len() as u64 / 16)?;
        store.0.execute(
            "INSERT OR IGNORE INTO speaker_blocks(meeting_id,cache_key,result_json) VALUES (?1,?2,?3)",
            rusqlite::params![meeting,key,output.to_string()],
        )?;
        Ok(output)
    }

    pub(crate) fn separate_group(
        &mut self,
        store: &Store,
        meeting: i64,
        samples: &[i16],
        scratch: &Path,
        offset_ms: u64,
        voices: &mut MeetingVoices,
    ) -> Result<Vec<Value>> {
        // A short final block is processed by the same worker.
        let mut turns = Vec::new();
        for (index, block) in samples.chunks(MAX_BLOCK_FRAMES).enumerate() {
            let result = self.separate(store, meeting, block, scratch)?;
            turns.extend(voices.merge(
                &result,
                block.len() as u64 / 16,
                offset_ms + index as u64 * 120_000,
            )?);
        }
        Ok(turns)
    }
}

#[derive(Default)]
pub(crate) struct MeetingVoices {
    // Each cluster keeps the mean of its normalized block embeddings.
    profiles: Vec<Option<(Vec<f64>, f64)>>,
}

impl MeetingVoices {
    pub(crate) fn from_snapshot(snapshot: &Value) -> Result<Self> {
        Ok(Self {
            profiles: serde_json::from_value(snapshot["profiles"].clone())?,
        })
    }

    pub(crate) fn snapshot(&self, fingerprint: &str) -> Value {
        json!({"fingerprint":fingerprint,"profiles":self.profiles})
    }

    fn merge(&mut self, result: &Value, duration: u64, offset: u64) -> Result<Vec<Value>> {
        let mut turns = parse_turns(result, duration)?;
        let local_ids = turns
            .iter()
            .map(|turn| turn["speaker_id"].as_str().unwrap().to_owned())
            .collect::<BTreeSet<_>>();
        let mut mapping = BTreeMap::new();
        let mut used = BTreeSet::new();
        let previous_count = self.profiles.len();
        for local in local_ids {
            let vector = result["voices"][local.trim_start_matches("speaker_")]
                .as_array()
                .and_then(|values| values.iter().map(Value::as_f64).collect::<Option<Vec<_>>>())
                .and_then(|values| normalize(&values).ok());
            let matched = vector.as_ref().and_then(|vector| {
                let mut scores = self.profiles[..previous_count]
                    .iter()
                    .enumerate()
                    .filter_map(|(id, profile)| {
                        let (profile, _) = profile.as_ref()?;
                        if profile.len() != vector.len() {
                            return None;
                        }
                        Some((
                            id,
                            profile.iter().zip(vector).map(|(a, b)| a * b).sum::<f64>(),
                        ))
                    })
                    .collect::<Vec<_>>();
                scores.sort_by(|a, b| b.1.total_cmp(&a.1));
                let &(id, best) = scores.first()?;
                let margin = best - scores.get(1).map_or(-1.0, |score| score.1);
                (best >= 0.72 && margin >= 0.08 && !used.contains(&id)).then_some(id)
            });
            let id = if let Some(id) = matched {
                let (profile, count) = self.profiles[id].as_mut().unwrap();
                let updated = profile
                    .iter()
                    .zip(vector.as_ref().unwrap())
                    .map(|(a, b)| a * *count + b)
                    .collect::<Vec<_>>();
                *profile = normalize(&updated)?;
                *count += 1.0;
                id
            } else {
                self.profiles.push(vector.map(|value| (value, 1.0)));
                self.profiles.len() - 1
            };
            used.insert(id);
            mapping.insert(local, id);
        }
        for turn in &mut turns {
            turn["speaker_id"] = json!(format!(
                "speaker_{}",
                mapping[turn["speaker_id"].as_str().unwrap()]
            ));
            for key in ["start_ms", "end_ms"] {
                turn[key] = json!(turn[key].as_u64().unwrap() + offset);
            }
        }
        Ok(turns)
    }
}

pub(crate) fn separate_file(
    store: &Store,
    meeting: i64,
    config: &DiarizationConfig,
    engine: &Path,
    wav: &Path,
    scratch: &Path,
    inputs: &[Value],
) -> Result<Vec<Value>> {
    let mut session = SpeakerSession::new(config, engine)?;
    let mut reader = hound::WavReader::open(wav)?;
    let mut samples = reader.samples::<i16>();
    let mut pending = inputs;
    let mut offset = 0u64;
    let mut voices = MeetingVoices::default();
    let mut turns = Vec::new();
    while let Some(first) = pending.first() {
        let mut count = 0;
        for _ in 0..GROUPS_PER_BLOCK {
            if pending
                .get(count)
                .is_none_or(|source| source["session_id"] != first["session_id"])
            {
                break;
            }
            count += capture_block_len(&pending[count..]);
            if first["session_id"].is_null() {
                break;
            }
        }
        let mut remaining = pending[..count]
            .iter()
            .map(|source| {
                source["normalized_frames"]
                    .as_u64()
                    .context("missing normalized frame count")
            })
            .sum::<Result<u64>>()?;
        while remaining > 0 {
            let size = remaining.min(MAX_BLOCK_FRAMES as u64) as usize;
            let block = samples
                .by_ref()
                .take(size)
                .collect::<std::result::Result<Vec<_>, _>>()?;
            if block.len() != size {
                bail!("truncated speaker audio");
            }
            turns.extend(session.separate_group(
                store,
                meeting,
                &block,
                scratch,
                offset / 16,
                &mut voices,
            )?);
            offset += size as u64;
            remaining -= size as u64;
        }
        pending = &pending[count..];
    }
    Ok(turns)
}
