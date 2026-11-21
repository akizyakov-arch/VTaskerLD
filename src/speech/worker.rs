use super::SpeechConfig;
use crate::Store;
use anyhow::{bail, Result};
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// The web process supervises a worker subprocess; inference never runs in HTTP handlers.
pub struct SpeechWorker {
    child: Option<std::process::Child>,
    last: Value,
    meeting: Option<i64>,
    pub settings: Value,
    pub api_key: String,
}
impl Default for SpeechWorker {
    fn default() -> Self {
        Self {
            child: None,
            last: Value::Null,
            meeting: None,
            settings: json!({"provider":"local"}),
            api_key: String::new(),
        }
    }
}
impl SpeechWorker {
    pub(crate) fn config(&self) -> Result<SpeechConfig> {
        self.local_config(self.speaker_detection_enabled())
    }

    pub(crate) fn local_config(&self, speaker_detection: bool) -> Result<SpeechConfig> {
        SpeechConfig::from_env_with_model(speaker_detection,
            self.settings["local_model"].as_str().filter(|path| !path.is_empty()))
    }

    pub(crate) fn speaker_detection_enabled(&self) -> bool {
        self.settings["speaker_detection"] != false
    }

    pub(crate) fn live_display_enabled(&self) -> bool {
        self.settings["live_display"] == true
    }
    pub fn status(&self) -> Value {
        {
            let config = self.config();
            let vad_enabled = config.as_ref().is_ok_and(|c| c.vad_model.is_some());
            let diarization_enabled = config.as_ref().is_ok_and(|c| c.diarization.is_some());
            let config_supports_speaker_blocks = config
                .as_ref()
                .is_ok_and(|c| c.diarization.as_ref().is_some_and(|d| d.speakers == 0))
                && self.settings["provider"] != "cloud"
                && super::blocks::engine().is_some();
            let configuration = config.and_then(|c| c.validate());
            json!({"settings":self.settings,"key_present":!self.api_key.is_empty(),"configured":configuration.is_ok() && (self.settings["provider"] != "cloud" || !self.api_key.is_empty()),"vad_enabled":vad_enabled,"diarization_enabled":diarization_enabled,"configuration_error":configuration.err().map(|e|e.to_string()),"running":self.child.is_some(),"block_processing":super::blocks::engine().is_some() && self.settings["provider"] != "cloud","speaker_blocks":super::speaker_blocks::engine().is_some() && config_supports_speaker_blocks,"last":self.last})
        }
    }
    pub fn start(&mut self, db: &Path) -> Result<()> {
        self.start_for(db, None)
    }
    pub fn start_for(&mut self, db: &Path, meeting: Option<i64>) -> Result<()> {
        if self.child.is_some() {
            bail!("worker already running");
        }
        self.config()?.validate()?;
        if self.settings["provider"] == "cloud" && self.api_key.is_empty() {
            bail!("Введите ключ облачного API в настройках");
        }
        let meeting = match meeting {
            Some(id) => id,
            None => Store::open(db)?.0.query_row(
                "SELECT meeting_id FROM processing_jobs WHERE status='pending' ORDER BY id LIMIT 1",
                [],
                |row| row.get(0),
            )?,
        };
        let mut command = Command::new(std::env::current_exe()?);
        #[cfg(unix)]
        command.process_group(0);
        command.arg("--db").arg(db).args(["jobs", "run"]);
        if let Some(model) = self.settings["local_model"]
            .as_str()
            .filter(|v| !v.is_empty())
        {
            command.env("VTRACKER_WHISPER_MODEL", model);
        }
        if self.settings["provider"] == "cloud" {
            command
                .env(
                    "VTRACKER_CLOUD_URL",
                    self.settings["url"].as_str().unwrap_or_default(),
                )
                .env(
                    "VTRACKER_CLOUD_MODEL",
                    self.settings["model"].as_str().unwrap_or_default(),
                )
                .env(
                    "VTRACKER_CLOUD_FORMAT",
                    self.settings["format"].as_str().unwrap_or("json"),
                )
                .env("VTRACKER_CLOUD_KEY", &self.api_key);
        } else {
            command
                .env_remove("VTRACKER_CLOUD_URL")
                .env_remove("VTRACKER_CLOUD_KEY");
        }
        command.args(["--meeting", &meeting.to_string()]);
        self.child = Some(
            command
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()?,
        );
        self.meeting = Some(meeting);
        self.last = Value::Null;
        Ok(())
    }
    pub fn cancel(&mut self, store: &Store, meeting: i64) -> Result<()> {
        if self.meeting != Some(meeting) || self.child.is_none() {
            bail!("У этой встречи нет активного обработчика распознавания");
        }
        let child = self.child.as_mut().unwrap();
        #[cfg(unix)]
        {
            // The worker and all model subprocesses share this dedicated process group.
            let result = unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL) };
            if result != 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() != Some(libc::ESRCH) {
                    return Err(error.into());
                }
            }
        }
        #[cfg(not(unix))]
        child.kill()?;
        child.wait()?;
        let tx = store.0.unchecked_transaction()?;
        tx.execute(
            "UPDATE model_runs SET status='failed' WHERE meeting_id=?1 AND status='running'",
            [meeting],
        )?;
        tx.execute(
            "UPDATE processing_jobs SET status='failed',error='Распознавание прервано пользователем',finished_at=unixepoch() WHERE meeting_id=?1 AND status IN ('running','pending')",
            [meeting],
        )?;
        tx.commit()?;
        self.child = None;
        self.meeting = None;
        self.last = json!({"success":false,"cancelled":true});
        Ok(())
    }

    pub fn poll(&mut self) -> Result<()> {
        if let Some(child) = self.child.as_mut() {
            if let Some(exit) = child.try_wait()? {
                self.last = json!({"success":exit.success(),"exit_code":exit.code()});
                self.child = None;
                self.meeting = None;
            }
        }
        Ok(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn cancellation_stops_owned_group_and_allows_retry() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(&temp.path().join("db")).unwrap();
        let meeting = store.create_meeting("Cancel").unwrap();
        let job = store.enqueue(meeting).unwrap();
        store
            .0
            .execute(
                "UPDATE processing_jobs SET status='running' WHERE id=?1",
                [job],
            )
            .unwrap();
        let marker = temp.path().join("descendant-survived");
        let child = Command::new("/bin/sh")
            .args(["-c", "(sleep 1; touch \"$1\") & wait", "fixture"])
            .arg(&marker)
            .process_group(0)
            .spawn()
            .unwrap();
        let mut worker = SpeechWorker {
            child: Some(child),
            meeting: Some(meeting),
            ..SpeechWorker::default()
        };
        assert!(worker.cancel(&store, meeting + 1).is_err());
        assert!(worker.child.is_some());
        std::thread::sleep(std::time::Duration::from_millis(100));
        worker.cancel(&store, meeting).unwrap();
        assert!(worker.child.is_none());
        assert_eq!(store.jobs().unwrap()[0]["status"], "failed");
        store.retry(job).unwrap();
        assert_eq!(store.jobs().unwrap()[0]["status"], "pending");
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert!(!marker.exists(), "descendant must stop with the worker");
    }
}
