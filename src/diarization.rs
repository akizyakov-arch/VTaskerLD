//! Speaker cluster labels are local to one model run, never person identities.
use crate::{audio::checksum, speech::resolve};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone)]
pub struct DiarizationConfig {
    pub engine: PathBuf,
    pub segmentation: PathBuf,
    pub embedding: PathBuf,
    pub speakers: u32,
    pub cluster_threshold: Option<f64>,
}
impl DiarizationConfig {
    pub fn from_env() -> Result<Option<Self>> {
        let names = [
            "VTRACKER_DIARIZATION_BIN",
            "VTRACKER_SEGMENTATION_MODEL",
            "VTRACKER_EMBEDDING_MODEL",
        ];
        let values: Vec<_> = names.iter().map(std::env::var_os).collect();
        if values.iter().all(Option::is_none) {
            if std::env::var_os("VTRACKER_SPEAKERS").is_some() {
                bail!("configure diarization models before setting VTRACKER_SPEAKERS");
            }
            return Ok(None);
        }
        if values.iter().any(Option::is_none) {
            bail!("set all three diarization paths: VTRACKER_DIARIZATION_BIN, VTRACKER_SEGMENTATION_MODEL, VTRACKER_EMBEDDING_MODEL");
        }
        let config = Self {
            engine: resolve(&PathBuf::from(values[0].as_ref().unwrap()))?,
            segmentation: std::fs::canonicalize(PathBuf::from(values[1].as_ref().unwrap()))?,
            embedding: std::fs::canonicalize(PathBuf::from(values[2].as_ref().unwrap()))?,
            cluster_threshold: std::env::var("VTRACKER_CLUSTER_THRESHOLD")
                .ok()
                .map(|value| value.parse::<f64>())
                .transpose()
                .context("VTRACKER_CLUSTER_THRESHOLD must be a number")?,
            speakers: std::env::var("VTRACKER_SPEAKERS")
                .unwrap_or_else(|_| "0".into())
                .parse()
                .context("VTRACKER_SPEAKERS must be 0 (auto) or 1..64")?,
        };
        config.validate()?;
        Ok(Some(config))
    }
    pub fn validate(&self) -> Result<()> {
        if self
            .cluster_threshold
            .is_some_and(|value| !(value > 0.0 && value <= 1.0))
        {
            bail!("clustering threshold must be greater than 0 and at most 1");
        }
        if self.speakers > 64 {
            bail!("speaker count must be 0 (auto) or 1..64");
        }
        for path in [&self.engine, &self.segmentation, &self.embedding] {
            if !path.is_file() {
                bail!("diarization file missing: {}", path.display());
            }
        }
        Ok(())
    }
    pub fn parameters(&self) -> Result<Value> {
        Ok(
            json!({"backend":"sherpa-onnx-c-api","engine_sha256":checksum(&self.engine)?,"segmentation_sha256":checksum(&self.segmentation)?,"embedding_sha256":checksum(&self.embedding)?,"num_speakers":self.speakers,"clustering_threshold":self.cluster_threshold.unwrap_or(0.5),"window_shift_ratio":0.1,"min_duration_on":0.2,"min_duration_off":0.5,"threads":4,"provider":"cpu"}),
        )
    }
}
pub fn parse_turns(output: &Value, duration: u64) -> Result<Vec<Value>> {
    let turns = output["turns"]
        .as_array()
        .context("diarization JSON missing turns array")?;
    let mut parsed = Vec::new();
    for turn in turns {
        let start = turn["start_ms"].as_u64().context("invalid speaker start")?;
        let end = turn["end_ms"].as_u64().context("invalid speaker end")?;
        let speaker = turn["speaker"]
            .as_u64()
            .context("invalid speaker cluster")?;
        if start >= duration || end <= start || end > duration.saturating_add(1000) || speaker > 63
        {
            bail!("invalid speaker interval or cluster");
        }
        parsed.push(json!({"start_ms":start,"end_ms":end.min(duration),"speaker_id":format!("speaker_{speaker}")}));
    }
    parsed.sort_by_key(|v| v["start_ms"].as_u64().unwrap());
    Ok(parsed)
}
/// Suppress isolated sub-second clusters close to a well-established voice.
pub fn suppress_transient_clusters(turns: &mut Vec<Value>, assignments: &[Value]) {
    let mut clusters = BTreeMap::<String, (usize, u64)>::new();
    for turn in turns.iter() {
        let cluster = clusters
            .entry(turn["speaker_id"].as_str().unwrap().into())
            .or_default();
        cluster.0 += 1;
        cluster.1 += turn["end_ms"].as_u64().unwrap() - turn["start_ms"].as_u64().unwrap();
    }
    let established: Vec<_> = turns
        .iter()
        .filter(|turn| clusters[turn["speaker_id"].as_str().unwrap()].1 >= 10_000)
        .map(|turn| {
            (
                turn["start_ms"].as_u64().unwrap(),
                turn["end_ms"].as_u64().unwrap(),
            )
        })
        .collect();
    turns.retain(|turn| {
        let speaker = turn["speaker_id"].as_str().unwrap();
        let (count, duration) = clusters[speaker];
        if count != 1 || duration >= 850 || assignments.iter().any(|a| a["speaker_id"] == speaker) {
            return true;
        }
        let start = turn["start_ms"].as_u64().unwrap();
        let end = turn["end_ms"].as_u64().unwrap();
        !established
            .iter()
            .any(|&(a, b)| start.saturating_sub(b).max(a.saturating_sub(end)) <= 1_000)
    });
}

/// Union overlap per cluster; no text is split at guessed word boundaries.
pub fn attribution(start: u64, end: u64, turns: &[Value]) -> Value {
    let mut by_speaker: BTreeMap<String, Vec<(u64, u64)>> = BTreeMap::new();
    for turn in turns {
        let a = start.max(turn["start_ms"].as_u64().unwrap());
        let b = end.min(turn["end_ms"].as_u64().unwrap());
        if b > a {
            by_speaker
                .entry(turn["speaker_id"].as_str().unwrap().to_owned())
                .or_default()
                .push((a, b));
        }
    }
    let mut concurrent = BTreeSet::new();
    let mut spans: Vec<_> = by_speaker.iter().flat_map(|(speaker, ranges)| {
        ranges.iter().map(move |&(start, end)| (start, end, speaker.as_str()))
    }).collect();
    spans.sort_unstable();
    for (index, &(start, end, speaker)) in spans.iter().enumerate() {
        for &(other_start, other_end, other) in spans[index + 1..].iter().take_while(|span| span.0 < end) {
            if speaker != other && start.max(other_start) < end.min(other_end) {
                concurrent.insert(speaker);
                concurrent.insert(other);
            }
        }
    }
    let overlapping_speakers = json!(concurrent);
    let mut candidates = Vec::new();
    for (speaker, mut intervals) in by_speaker {
        intervals.sort();
        let mut total = 0;
        let mut current = intervals[0];
        for interval in intervals.into_iter().skip(1) {
            if interval.0 <= current.1 {
                current.1 = current.1.max(interval.1);
            } else {
                total += current.1 - current.0;
                current = interval;
            }
        }
        total += current.1 - current.0;
        candidates.push(json!({"speaker_id":speaker,"overlap_ms":total}));
    }
    let single = candidates.len() == 1
        && end > start
        && candidates[0]["overlap_ms"].as_u64().unwrap() >= (end - start).div_ceil(2);
    json!({"speaker_id":if single {candidates[0]["speaker_id"].clone()} else {Value::Null},"speaker_status":if single {"single"} else if candidates.len()>1 {"multiple"} else {"unknown"},"speaker_candidates":candidates,"overlapping_speakers":overlapping_speakers})
}

pub(crate) fn dominant_speaker_candidate(
    start: u64, end: u64, attribution: &Value,
) -> Option<&Value> {
    let duration = end.checked_sub(start)?;
    if duration == 0 { return None; }
    let candidates = attribution["speaker_candidates"].as_array()?;
    let main = candidates.iter().max_by_key(|candidate| candidate["overlap_ms"].as_u64())?;
    let main_ms = main["overlap_ms"].as_u64()?;
    let other_ms: u64 = candidates.iter().filter(|item| item["speaker_id"] != main["speaker_id"])
        .filter_map(|item| item["overlap_ms"].as_u64()).sum();
    (main_ms.saturating_mul(5) >= duration.saturating_mul(4)
        && other_ms.saturating_mul(5) <= duration).then_some(main)
}
