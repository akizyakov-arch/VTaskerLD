use anyhow::Result;
use clap::{Parser, Subcommand, ValueEnum};
use std::path::PathBuf;
use vtracker::Store;

#[derive(Parser)]
#[command(version, about = "VTracker — локальное ядро истории встреч")]
struct Cli {
    #[arg(long, default_value = ".vtracker/data.sqlite3")]
    db: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Enumerate or test macOS microphones. No audio is saved by `test`.
    Devices {
        #[command(subcommand)]
        command: Devices,
    },
    /// Internal bounded Live worker; do not run concurrently with another worker.
    #[command(hide = true)]
    LiveChunk {
        id: i64,
        #[arg(long)]
        scratch: PathBuf,
    },
    #[command(hide = true)]
    LiveBlocks {
        session: String,
        #[arg(long)]
        scratch: PathBuf,
    },
    #[command(hide = true)]
    VoiceRun {
        id: i64,
        #[arg(long)]
        scratch: PathBuf,
    },
    #[command(hide = true)]
    VoiceMatchRun {
        id: i64,
        #[arg(long)]
        scratch: PathBuf,
    },
    /// Initialize storage; safe to repeat.
    Init,
    /// Start the local web management panel.
    Serve,
    Speaker {
        #[command(subcommand)]
        command: Speaker,
    },
    /// Import or recover finalized WAV audio fragments.
    Audio {
        #[command(subcommand)]
        command: Audio,
    },
    People {
        #[command(subcommand)]
        command: People,
    },
    Meeting {
        #[command(subcommand)]
        command: Meeting,
    },
    Jobs {
        #[command(subcommand)]
        command: Jobs,
    },
    /// Export meeting metadata; transcript is unavailable until speech processing exists.
    Export {
        meeting_id: i64,
        #[arg(long, value_enum, default_value = "json")]
        format: Format,
    },
}
#[derive(Subcommand)]
enum Devices {
    List,
    Test {
        #[arg(long)]
        device: Option<String>,
        #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u64).range(1..=30))]
        seconds: u64,
    },
}
#[derive(Subcommand)]
enum Speaker {
    Assign {
        model_run_id: i64,
        speaker_id: String,
        person_id: i64,
    },
    Unassign {
        model_run_id: i64,
        speaker_id: String,
    },
    History {
        model_run_id: i64,
    },
}
#[derive(Subcommand)]
enum People {
    Add {
        name: String,
    },
    List,
    Voices,
    EnrollSpeaker {
        #[arg(long)]
        run: bool,
        person_id: i64,
        model_run_id: i64,
        speaker_id: String,
        #[arg(long)]
        consent: bool,
        #[arg(long)]
        single_speaker: bool,
    },
    MatchVoices {
        model_run_id: i64,
        #[arg(long)]
        run: bool,
    },
    Enroll {
        person_id: i64,
        file: PathBuf,
        #[arg(long)]
        consent: bool,
        #[arg(long)]
        single_speaker: bool,
        #[arg(long)]
        run: bool,
    },
}
#[derive(Subcommand)]
enum Meeting {
    Transcript {
        meeting_id: i64,
        #[arg(long)]
        live: bool,
    },
    /// Requires a running local `serve` process.
    Start {
        meeting_id: i64,
        #[arg(long, default_value_t = 7200)]
        seconds: u64,
        #[arg(long)]
        device: Option<String>,
        #[arg(long)]
        live: bool,
    },
    Continue {
        meeting_id: i64,
        #[arg(long, default_value_t = 7200)]
        seconds: u64,
        #[arg(long)]
        device: Option<String>,
        #[arg(long)]
        live: bool,
    },
    Stop {
        meeting_id: i64,
    },
    /// After a server crash only: confirm no capture process remains first.
    Recover {
        meeting_id: i64,
    },
    Create {
        title: String,
    },
    List,
}
#[derive(Subcommand)]
enum Jobs {
    /// Process one pending job using local Whisper and environment configuration.
    Run {
        #[arg(long)]
        meeting: Option<i64>,
    },
    /// Operator recovery only, after verifying the worker has stopped.
    Recover {
        id: i64,
    },
    Enqueue {
        meeting_id: i64,
    },
    List,
    Retry {
        id: i64,
    },
}
#[derive(Subcommand)]
enum Audio {
    Import {
        meeting_id: i64,
        file: PathBuf,
        #[arg(long, default_value = ".vtracker/audio")]
        root: PathBuf,
    },
    Recover {
        meeting_id: i64,
        #[arg(long, default_value = ".vtracker/audio")]
        root: PathBuf,
    },
    List {
        meeting_id: i64,
    },
}
#[derive(Clone, ValueEnum)]
enum Format {
    Json,
    Txt,
}
fn main() -> Result<()> {
    let cli = Cli::parse();
    if matches!(cli.command, Command::Serve) {
        return vtracker::web::serve(&cli.db);
    }
    if let Command::Devices { command } = &cli.command {
        let helper = vtracker::capture::default_helper();
        match command {
            Devices::List => println!(
                "{}",
                serde_json::to_string_pretty(&vtracker::capture::devices(&helper)?)?
            ),
            Devices::Test { device, seconds } => {
                let mut command = std::process::Command::new(helper);
                command.arg("--test").arg(seconds.to_string());
                if let Some(uid) = device {
                    command.arg(uid);
                }
                if !command.status()?.success() {
                    anyhow::bail!("Microphone test failed");
                }
            }
        }
        return Ok(());
    }
    let store = Store::open(&cli.db)?;
    match cli.command {
        Command::Serve | Command::Devices { .. } => unreachable!(),
        Command::VoiceMatchRun { id, scratch } => {
            store.run_voice_matching(id, &scratch, &vtracker::voice::VoiceConfig::from_env()?)?;
        }
        Command::VoiceRun { id, scratch } => {
            let root = cli
                .db
                .parent()
                .unwrap_or(std::path::Path::new("."))
                .join("voice");
            store.run_voice_job(
                id,
                &root,
                &scratch,
                &vtracker::voice::VoiceConfig::from_env()?,
            )?;
        }
        Command::LiveBlocks { session, scratch } => {
            store.run_live_blocks(&session, vtracker::speech::SpeechConfig::from_env()?, &scratch)?;
        }
        Command::LiveChunk { id, scratch } => {
            store.run_live_chunk(id, vtracker::speech::SpeechConfig::from_env()?, &scratch)?;
        }
        Command::Audio { command } => match command {
            Audio::Import {
                meeting_id,
                file,
                root,
            } => println!("{}", store.import_wav(meeting_id, &file, &root)?),
            Audio::Recover { meeting_id, root } => println!(
                "Checked {} published WAVs and {} capture fragments",
                store.recover_audio(meeting_id, &root)?,
                store.recover_capture(meeting_id, &root)?
            ),
            Audio::List { meeting_id } => println!(
                "{}",
                serde_json::to_string_pretty(&store.recordings(meeting_id)?)?
            ),
        },
        Command::Speaker { command } => match command {
            Speaker::Assign {
                model_run_id,
                speaker_id,
                person_id,
            } => println!(
                "{}",
                store.assign_speaker(model_run_id, &speaker_id, Some(person_id))?
            ),
            Speaker::Unassign {
                model_run_id,
                speaker_id,
            } => println!("{}", store.assign_speaker(model_run_id, &speaker_id, None)?),
            Speaker::History { model_run_id } => println!(
                "{}",
                serde_json::to_string_pretty(&store.speaker_assignments(model_run_id, true)?)?
            ),
        },
        Command::Init => println!("Storage initialized"),
        Command::People { command } => match command {
            People::Add { name } => println!("{}", store.add_person(&name)?),
            People::List => println!("{}", serde_json::to_string_pretty(&store.people()?)?),
            People::EnrollSpeaker {
                run,
                person_id,
                model_run_id,
                speaker_id,
                consent,
                single_speaker,
            } => {
                let job = store.queue_voice_from_meeting(
                    person_id,
                    model_run_id,
                    &speaker_id,
                    consent,
                    single_speaker,
                )?;
                if run {
                    let root = cli
                        .db
                        .parent()
                        .unwrap_or(std::path::Path::new("."))
                        .join("voice");
                    store.run_voice_job(
                        job,
                        &root,
                        tempfile::tempdir()?.path(),
                        &vtracker::voice::VoiceConfig::from_env()?,
                    )?;
                }
                println!("{}", serde_json::json!({"job_id":job}));
            }
            People::MatchVoices { model_run_id, run } => {
                let job = store.queue_voice_matching(model_run_id)?;
                if run {
                    store.run_voice_matching(
                        job,
                        tempfile::tempdir()?.path(),
                        &vtracker::voice::VoiceConfig::from_env()?,
                    )?;
                }
                println!("{}", serde_json::json!({"job_id":job}));
            }
            People::Voices => println!("{}", store.voice_snapshot()?),
            People::Enroll {
                person_id,
                file,
                consent,
                single_speaker,
                run,
            } => {
                let root = cli
                    .db
                    .parent()
                    .unwrap_or(std::path::Path::new("."))
                    .join("voice");
                let id =
                    store.queue_voice_sample(person_id, &file, &root, consent, single_speaker)?;
                if run {
                    store.run_voice_job(
                        id,
                        &root,
                        tempfile::tempdir()?.path(),
                        &vtracker::voice::VoiceConfig::from_env()?,
                    )?;
                }
                println!("{}", serde_json::json!({"job_id":id}));
            }
        },
        Command::Meeting { command } => match command {
            Meeting::Start {
                meeting_id,
                seconds,
                device,
                live,
            } => println!(
                "{}",
                vtracker::capture::control_mode(
                    "start",
                    meeting_id,
                    seconds,
                    device.as_deref(),
                    if live { Some("live") } else { None }
                )?
            ),
            Meeting::Continue {
                meeting_id,
                seconds,
                device,
                live,
            } => println!(
                "{}",
                vtracker::capture::control_mode(
                    "continue",
                    meeting_id,
                    seconds,
                    device.as_deref(),
                    if live { Some("live") } else { None }
                )?
            ),
            Meeting::Stop { meeting_id } => {
                println!("{}", vtracker::capture::control("stop", meeting_id, 0)?)
            }
            Meeting::Recover { meeting_id } => {
                store.interrupt_capture(meeting_id)?;
                println!("Meeting marked failed; inspect staging files before audio import");
            }
            Meeting::Transcript { meeting_id, live } => println!(
                "{}",
                serde_json::to_string_pretty(&if live {
                    store.live_snapshot(meeting_id)?
                } else {
                    store.transcript(meeting_id)?
                })?
            ),
            Meeting::Create { title } => println!("{}", store.create_meeting(&title)?),
            Meeting::List => println!("{}", serde_json::to_string_pretty(&store.meetings()?)?),
        },
        Command::Jobs { command } => match command {
            Jobs::Run { meeting } => {
                let config = vtracker::speech::SpeechConfig::from_env()?;
                println!(
                    "{}",
                    serde_json::json!({"completed_job":store.run_meeting(&config,meeting)?})
                );
            }
            Jobs::Recover { id } => {
                store.recover_job(id)?;
                println!("Interrupted job marked failed; use jobs retry to enqueue it");
            }
            Jobs::Enqueue { meeting_id } => println!("{}", store.enqueue(meeting_id)?),
            Jobs::List => println!("{}", serde_json::to_string_pretty(&store.jobs()?)?),
            Jobs::Retry { id } => {
                store.retry(id)?;
                println!("Job queued");
            }
        },
        Command::Export { meeting_id, format } => {
            let data = store.export(meeting_id)?;
            match format {
                Format::Json => println!("{}", serde_json::to_string_pretty(&data)?),
                Format::Txt => println!(
                    "{}\nStatus: {}\nCreated: {}\n{}",
                    data["meeting"]["title"].as_str().unwrap_or_default(),
                    data["meeting"]["status"].as_str().unwrap_or_default(),
                    data["meeting"]["created_at"].as_str().unwrap_or_default(),
                    vtracker::speech::transcript_text(&data["transcript"])
                ),
            }
        }
    }
    Ok(())
}
