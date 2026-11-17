//! Opt-in real macOS TTS -> five-second capture fragments -> full Whisper -> Groq test.
//! Uses a fresh synthetic database and never records the user's microphone.
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::Instant,
};
use vtracker::{groq::MODELS, speech::SpeechConfig, Store};
fn write(path: impl AsRef<Path>, v: &Value) -> Result<()> {
    fs::write(path, serde_json::to_vec_pretty(v)?)?;
    Ok(())
}
fn helper(mode: &str, out: &Path) -> Result<()> {
    let result = Command::new("python3")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/full_meeting_audio.py"))
        .arg(mode)
        .arg(out)
        .status()?;
    anyhow::ensure!(result.success(), "Full-meeting {mode} helper failed");
    Ok(())
}
#[test]
#[ignore = "Requires installed macOS Milena, actual Whisper models and explicit VTASK_FULL_GROQ=1 for paid API"]
fn full_synthetic_meeting_preserves_audio_context_and_action_items() -> Result<()> {
    let out = PathBuf::from(
        std::env::var("VTASK_FULL_MEETING_DIR").context("Set a new output directory")?,
    );
    fs::create_dir_all(&out)?;
    anyhow::ensure!(
        !out.join("data.sqlite3").exists(),
        "Choose a fresh test directory"
    );
    helper("prepare", &out)?;
    let manifest: Value = serde_json::from_slice(&fs::read(out.join("audio_manifest.json"))?)?;
    println!(
        "Audio: {} seconds / {} five-second fragments",
        manifest["seconds"], manifest["fragments"]
    );
    let path = out.join("data.sqlite3");
    let s = Store::open(&path)?;
    let people = [
        s.add_person("Анна")?,
        s.add_person("Борис")?,
        s.add_person("Виктор")?,
    ];
    let m=s.workspace_action(&json!({"op":"save_meeting","data":{"title":"Полное синтетическое совещание","participants":people}}))?["id"].as_i64().unwrap();
    s.workspace_action(
        &json!({"op":"settings","data":{"timezone":"Europe/Moscow","initialized":true}}),
    )?;
    rusqlite::Connection::open(&path)?.execute(
        "UPDATE meetings SET created_at='2026-11-02T12:00:00Z',status='completed' WHERE id=?1",
        [m],
    )?;
    s.workspace_action(&json!({"op":"save_meeting_notes","meeting_id":m,"revision":0,"summary":"Контроль: ручные заметки не менять","open_questions":""}))?;
    let mut pieces: Vec<_> = fs::read_dir(out.join("pieces"))?
        .map(|p| p.map(|p| p.path()))
        .collect::<std::io::Result<_>>()?;
    pieces.sort();
    let split = pieces.len() / 2;
    let mut expected_frames = 0u64;
    for (i, p) in pieces.iter().enumerate() {
        let (session, seq) = if i < split {
            (format!("{m}-10001"), i)
        } else {
            (format!("{m}-10002"), i - split)
        };
        expected_frames += hound::WavReader::open(p)?.duration() as u64;
        s.import_fragment(m, &session, seq as u32, p, &out.join("audio"))?;
    }
    let inputs = s.audio_inputs(m)?;
    assert_eq!(inputs.len(), pieces.len());
    assert_eq!(
        inputs
            .iter()
            .map(|v| v["frames"].as_u64().unwrap())
            .sum::<u64>(),
        expected_frames
    );
    s.enqueue(m)?;
    let began = Instant::now();
    s.run_next(&SpeechConfig::from_env()?)?;
    let asr_secs = began.elapsed().as_secs_f64();
    let t = s.transcript(m)?;
    write(out.join("transcript.json"), &t)?;
    let full_text = t["segments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["text"].as_str().unwrap())
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(out.join("transcript.txt"), &full_text)?;
    let calls = fs::read_to_string(out.join("engine_calls.jsonl"))?;
    assert_eq!(
        calls.lines().count(),
        1,
        "Final ASR must run once on the full track"
    );
    let segments = t["segments"].as_array().unwrap();
    assert!(!segments.is_empty());
    assert!(
        segments.last().unwrap()["end_ms"].as_u64().unwrap()
            > expected_frames * 1000 / 16000 - 15000,
        "Meeting ending must be transcribed"
    );
    assert!(
        segments
            .iter()
            .any(|s| s["sources"].as_array().unwrap().len() > 1),
        "At least one utterance must cross a storage boundary"
    );
    let (id, input, cached) = s.groq_prepare(m, MODELS[0], true)?;
    assert!(!cached);
    assert_eq!(input["segments"].as_array().unwrap().len(), segments.len());
    write(out.join("analysis_input.json"), &input)?;
    let began = Instant::now();
    helper("groq", &out)?;
    let groq_secs = began.elapsed().as_secs_f64();
    let result: Value = serde_json::from_slice(&fs::read(out.join("analysis_result.json"))?)?;
    s.groq_complete(id, &result)?;
    let w = s.workspace(false, None)?;
    assert!(w["tasks"].as_array().unwrap().is_empty());
    assert_eq!(
        s.meeting_notes(m)?["summary"],
        "Контроль: ручные заметки не менять"
    );
    let proposals: Vec<_> = w["proposals"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["kind"] == "create_task")
        .collect();
    let matching = |words: &[&str]| -> Vec<&Value> {
        proposals
            .iter()
            .copied()
            .filter(|p| {
                let text = format!(
                    "{} {}",
                    p["title"].as_str().unwrap_or(""),
                    p["description"].as_str().unwrap_or("")
                )
                .to_lowercase();
                words.iter().all(|word| text.contains(word))
            })
            .collect()
    };
    let groups = [
        ("contract", vec!["договор"]),
        ("form", vec!["форм"]),
        ("budget", vec!["смет"]),
        ("clients", vec!["спис", "клиент"]),
        ("access", vec!["доступ"]),
        ("save_results", vec!["сохран", "результат"]),
    ];
    let checks: Vec<_> = groups
        .iter()
        .map(|(name, words)| json!({"group":name,"found":!matching(words).is_empty()}))
        .collect();
    let excluded: Vec<_> = proposals
        .iter()
        .filter(|p| {
            let title = p["title"].as_str().unwrap_or("").to_lowercase();
            (title.contains("принтер") && (title.contains("куп") || title.contains("закуп")))
                || (title.contains("страниц") && title.contains("новост"))
                || (title.contains("отправ") && title.contains("старый отчёт"))
                || (title.contains("следующ")
                    && title.contains("встреч")
                    && (title.contains("назнач")
                        || title.contains("согласов")
                        || title.contains("определ")))
        })
        .collect();
    let budget = matching(&["смет"]);
    let budget_due_correct =
        !budget.is_empty() && budget.iter().all(|p| p["due_date"] == "2026-11-04");
    let client = matching(&["спис", "клиент"]);
    let client_owner_unknown =
        !client.is_empty() && client.iter().all(|p| p["assignee_id"].is_null());
    let report = json!({"synthetic":true,"real_microphone_tested":false,"synthesized_speakers":1,"audio":manifest,"asr_seconds":asr_secs,"groq_seconds":groq_secs,"asr_calls":1,"pcm_equal":true,"segments":segments.len(),"cross_fragment_segments":segments.iter().filter(|s|s["sources"].as_array().unwrap().len()>1).count(),"task_proposals":proposals.len(),"expected_action_groups":checks,"cancelled_or_completed_tasks":excluded.len(),"corrected_budget_deadline":budget_due_correct,"unnamed_client_owner_preserved":client_owner_unknown,"tasks_before_confirmation":0,"artifacts":out});
    write(out.join("report.json"), &report)?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    assert!(
        checks.iter().all(|v| v["found"] == true),
        "Missing action group; see report.json"
    );
    assert!(excluded.is_empty(), "Cancelled task extracted");
    assert!(budget_due_correct, "Later deadline correction was lost");
    assert!(
        client_owner_unknown,
        "An owner was invented for unassigned work"
    );
    let p = proposals[0];
    let approved = json!({"title":p["title"],"description":p["description"],"project_id":null,"assignee_id":p["assignee_id"],"author_id":null,"stage_id":"todo","priority":"normal","due_date":p["due_date"],"due_time":null,"blocked":false,"blocked_reason":"","dependencies":[]});
    s.workspace_action(&json!({"op":"review","id":p["id"],"data":approved}))?;
    assert_eq!(
        s.workspace(false, None)?["tasks"].as_array().unwrap().len(),
        1
    );
    assert!(s.groq_prepare(m, MODELS[0], true)?.2);
    assert_eq!(
        s.workspace(false, None)?["proposals"]
            .as_array()
            .unwrap()
            .len(),
        w["proposals"].as_array().unwrap().len()
    );
    let mut final_report = report;
    final_report["task_confirmation_passed"] = json!(true);
    final_report["cached_retry_without_duplicates"] = json!(true);
    write(out.join("report.json"), &final_report)?;
    Ok(())
}
