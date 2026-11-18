use crate::Store;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

pub fn server_address() -> Result<String> {
    let port = std::env::var("VTRACKER_PORT")
        .unwrap_or_else(|_| "8765".into())
        .parse::<u16>()
        .context("Некорректный локальный порт")?;
    if port == 0 {
        bail!("Порт должен быть от 1 до 65535");
    }
    Ok(format!("127.0.0.1:{port}"))
}
fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name, value).unwrap()
}
fn body(request: &mut Request, max: u64) -> Result<Value> {
    if request.body_length().unwrap_or(0) as u64 > max {
        bail!("Запрос слишком большой");
    }
    let mut bytes = Vec::new();
    request.as_reader().take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        bail!("Запрос слишком большой");
    }
    Ok(serde_json::from_slice(&bytes)?)
}
fn send_json(request: Request, result: Result<Value>) -> Result<()> {
    let (status, value) = match result {
        Ok(v) => (200, v),
        Err(e) => (400, json!({"error":e.to_string()})),
    };
    request.respond(
        Response::from_string(value.to_string())
            .with_status_code(status)
            .with_header(header("Content-Type", "application/json; charset=utf-8"))
            .with_header(header("Cache-Control", "no-store"))
            .with_header(header("X-Content-Type-Options", "nosniff")),
    )?;
    Ok(())
}
fn audio(request: Request, store: &Store, id: i64) -> Result<()> {
    let path: String =
        match store
            .0
            .query_row("SELECT path FROM recordings WHERE id=?1", [id], |r| {
                r.get(0)
            }) {
            Ok(p) => p,
            Err(e) => return send_json(request, Err(e.into())),
        };
    stream_audio(request, path.into());
    Ok(())
}
fn stream_audio(request: Request, path: std::path::PathBuf) {
    // Playback may read slowly or open a new range while an earlier request is still active.
    std::thread::spawn(move || {
        let _ = audio_file(request, &path);
    });
}

fn audio_file(request: Request, path: &Path) -> Result<()> {
    let mut file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => return send_json(request, Err(anyhow::anyhow!("Аудиофайл недоступен: {e}"))),
    };
    let total = file.metadata()?.len();
    let range = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("Range"))
        .map(|h| h.value.as_str().to_owned());
    let parsed = range
        .as_ref()
        .map(|s| -> Result<(u64, u64)> {
            let (start, end) = s
                .strip_prefix("bytes=")
                .context("Некорректный Range")?
                .split_once('-')
                .context("Некорректный Range")?;
            let a = if start.is_empty() {
                total.saturating_sub(end.parse::<u64>()?)
            } else {
                start.parse()?
            };
            let b = if end.is_empty() || start.is_empty() {
                total.saturating_sub(1)
            } else {
                end.parse::<u64>()?.min(total.saturating_sub(1))
            };
            if a >= total || a > b {
                bail!("Range вне файла");
            }
            Ok((a, b))
        })
        .transpose();
    match parsed {
        Ok(Some((start, end))) => {
            file.seek(SeekFrom::Start(start))?;
            request.respond(Response::new(
                StatusCode(206),
                vec![
                    header("Content-Type", "audio/wav"),
                    header("Accept-Ranges", "bytes"),
                    header("Content-Range", &format!("bytes {start}-{end}/{total}")),
                    header("Cache-Control", "no-store"),
                ],
                file.take(end - start + 1),
                Some((end - start + 1) as usize),
                None,
            ))?;
        }
        Ok(None) => request.respond(
            Response::from_file(file)
                .with_header(header("Content-Type", "audio/wav"))
                .with_header(header("Accept-Ranges", "bytes"))
                .with_header(header("Cache-Control", "no-store")),
        )?,
        Err(_) => request.respond(
            Response::empty(416).with_header(header("Content-Range", &format!("bytes */{total}"))),
        )?,
    }
    Ok(())
}
pub fn serve(path: &Path) -> Result<()> {
    let address = server_address()?;
    let origin = format!("http://{address}");
    let store = Store::open(path)?;
    let server = Server::http(&address).map_err(|e| anyhow::anyhow!("{e}"))?;
    eprintln!("VTASK: {origin}. Закрытие вкладки не останавливает запись. Остановите запись в панели перед выходом из сервера.");
    let root = path.parent().unwrap_or(Path::new(".")).join("audio");
    let mut capture =
        crate::capture::CaptureManager::new(crate::capture::default_helper(), root.clone());
    let mut worker = crate::speech::SpeechWorker::default();
    if let Ok(raw) = store.0.query_row(
        "SELECT data_json FROM workspace_settings WHERE key='speech'",
        [],
        |r| r.get::<_, String>(0),
    ) {
        worker.settings = serde_json::from_str(&raw)?;
    }
    let mut microphone = store
        .0
        .query_row(
            "SELECT data_json FROM workspace_settings WHERE key='microphone'",
            [],
            |r| r.get::<_, String>(0),
        )
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or(json!({"uid":""}));
    let mut inventory =
        crate::capture::devices(&crate::capture::default_helper()).unwrap_or(json!([]));
    let mut mic_test = crate::capture::MicrophoneTest::default();
    let mut live = crate::live::LiveWorker::default();
    let mut live_voice =
        crate::live_voice::LiveVoiceWorker::new(crate::voice::VoiceConfig::from_env().ok());
    let mut voice = crate::voice::VoiceWorker::default();
    let voice_root = path.parent().unwrap_or(Path::new(".")).join("voice");
    let mut voice_capture = crate::voice_capture::VoiceCapture::new(
        path.parent().unwrap_or(Path::new(".")).join("voice-drafts"),
        crate::capture::default_helper(),
    )?;
    let mut groq = crate::groq::GroqWorker::new(path, &store)?;
    let mut final_waiting: Option<i64> = None;
    let mut auto_seen = Value::Null;
    let mut auto_error: Option<String> = None;
    loop {
        groq.poll(&store)?;
        worker.poll()?;
        groq.poll_automatic(&store)?;
        voice.poll(path, &store, false)?;
        mic_test.poll()?;
        voice_capture.poll()?;
        capture.poll(&store)?;
        let capture_status = capture.status();
        groq.poll_live(&store, &capture_status["active"])?;
        if let Err(error) = live_voice.poll(
            path,
            &store,
            &capture_status["active"],
            !store.live_busy()?
                && !voice.busy()
                && worker.status()["running"] != true
                && !voice_capture.busy(),
        ) {
            live_voice.fail(format!("Live-подсказка недоступна: {error}"));
        }
        let live_capturing = !capture_status["active"].is_null();
        if let Err(error) = if live_voice.busy() {
            Ok(())
        } else {
            live.poll(path, &store, live_capturing)
        } {
            // No Live error propagates into capture ownership or the audio writer.
            live.last_error = Some(error.to_string());
            if let Some(session) = &live.session {
                let _ = store.defer_live(
                    session,
                    "Live недоступен. Запись продолжается; обработайте аудио после встречи",
                );
            }
        }
        let last = &capture_status["last"];
        if !last.is_null() && *last != auto_seen {
            auto_seen = last.clone();
            auto_error = None;
            if last["state"] == "completed" && store.auto_process_enabled()? {
                final_waiting = last["meeting_id"].as_i64();
            }
        }
        if final_waiting.is_some()
            && !voice_capture.busy()
            && !live_voice.busy()
            && !live.busy()
            && capture_status["active"].is_null()
        {
            let meeting = final_waiting.take().unwrap();
            let outcome = (|| -> Result<()> {
                if worker.status()["configured"] != true {
                    bail!("Аудио сохранено. Распознавание не запущено: модели не настроены. Откройте настройки.");
                }
                if store.live_busy()? {
                    bail!("Live был прерван. Подтвердите остановку прежних процессов в карточке встречи, затем запустите обработку.");
                }
                let pending = store.jobs()?.as_array().unwrap().iter().any(|j| {
                    j["meeting_id"] == meeting
                        && (j["status"] == "pending" || j["status"] == "running")
                });
                if !pending {
                    store.enqueue(meeting)?;
                }
                worker.start_for(path, Some(meeting))?;
                Ok(())
            })();
            if let Err(error) = outcome {
                auto_error = Some(error.to_string());
            }
        }
        voice.poll(
            path,
            &store,
            capture.status()["active"].is_null()
                && !live.busy()
                && worker.status()["running"] != true
                && !mic_test.active()
                && !live_voice.busy()
                && !voice_capture.busy()
                && final_waiting.is_none(),
        )?;
        let Some(mut request) = server.recv_timeout(std::time::Duration::from_millis(100))? else {
            continue;
        };
        if request
            .headers()
            .iter()
            .find(|h| h.field.equiv("Host"))
            .map(|h| h.value.as_str())
            != Some(address.as_str())
        {
            request.respond(Response::from_string("Invalid host").with_status_code(403))?;
            continue;
        }
        let method = request.method().clone();
        let full_url = request.url().to_string();
        let (url, query) = full_url.split_once('?').unwrap_or((&full_url, ""));
        if method == Method::Post
            && request
                .headers()
                .iter()
                .find(|h| h.field.equiv("Origin"))
                .map(|h| h.value.as_str())
                != Some(origin.as_str())
        {
            request.respond(Response::from_string("Invalid origin").with_status_code(403))?;
            continue;
        }
        if let Some(id) = url.strip_prefix("/api/people/photo/") {
            let id = id.parse::<i64>().context("Некорректный участник");
            match method {
                Method::Get => match id.and_then(|id| store.person_photo(id)) {
                    Ok(Some(photo)) => request.respond(Response::from_data(photo)
                        .with_header(header("Content-Type", "image/jpeg"))
                        .with_header(header("Cache-Control", "no-store"))
                        .with_header(header("X-Content-Type-Options", "nosniff")))?,
                    Ok(None) => request.respond(Response::empty(404))?,
                    Err(error) => send_json(request, Err(error))?,
                },
                Method::Post => {
                    let result = (|| -> Result<Value> {
                        let id = id?;
                        if !request.headers().iter().any(|h| {
                            h.field.equiv("Content-Type") && h.value.as_str() == "image/jpeg"
                        }) {
                            bail!("Нужно фото JPEG");
                        }
                        let mut photo = Vec::new();
                        request.as_reader().take(512 * 1024 + 1).read_to_end(&mut photo)?;
                        store.save_person_photo(id, (!photo.is_empty()).then_some(photo.as_slice()))?;
                        Ok(json!({"id":id}))
                    })();
                    send_json(request, result)?;
                }
                _ => request.respond(Response::empty(405))?,
            }
            continue;
        }
        if method == Method::Get {
            if let Some(id) = url.strip_prefix("/api/voice/capture/audio/") {
                match voice_capture.audio(id) {
                    Ok(path) => stream_audio(request, path),
                    Err(e) => send_json(request, Err(e))?,
                };
                continue;
            }
            let asset = match url {
                "/" => Some((
                    include_str!("../web/index.html"),
                    "text/html; charset=utf-8",
                )),
                "/app.js" => Some((
                    include_str!("../web/app.js"),
                    "text/javascript; charset=utf-8",
                )),
                "/domain.mjs" => Some((
                    include_str!("../web/domain.mjs"),
                    "text/javascript; charset=utf-8",
                )),
                "/service.mjs" => Some((
                    include_str!("../web/service.mjs"),
                    "text/javascript; charset=utf-8",
                )),
                "/vtask-light.svg" => Some((
                    include_str!("../web/vtask-light.svg"),
                    "image/svg+xml",
                )),
                "/vtask-dark.svg" => Some((
                    include_str!("../web/vtask-dark.svg"),
                    "image/svg+xml",
                )),
                "/styles.css" => {
                    Some((include_str!("../web/styles.css"), "text/css; charset=utf-8"))
                }
                _ => None,
            };
            if let Some((content, mime)) = asset {
                request.respond(
                    Response::from_string(content)
                        .with_header(header("Content-Type", mime))
                        .with_header(header("Cache-Control", "no-cache"))
                        .with_header(header("X-Content-Type-Options", "nosniff")),
                )?;
                continue;
            }
            if let Some(value) = url.strip_prefix("/api/audio/") {
                let parsed = value.parse::<i64>();
                match parsed {
                    Ok(id) => audio(request, &store, id)?,
                    Err(e) => send_json(request, Err(e.into()))?,
                }
                continue;
            }
            if let Some(value) = url.strip_prefix("/api/export/") {
                let result = (|| -> Result<String> {
                    let data = store.export(value.parse()?)?;
                    Ok(if query == "format=txt" {
                        format!(
                            "{}\n{}",
                            data["meeting"]["title"].as_str().unwrap_or_default(),
                            crate::speech::transcript_text(&data["transcript"])
                        )
                    } else {
                        serde_json::to_string_pretty(&data)?
                    })
                })();
                match result {
                    Ok(data) => {
                        let txt = query == "format=txt";
                        request.respond(
                            Response::from_string(data)
                                .with_header(header(
                                    "Content-Type",
                                    if txt {
                                        "text/plain; charset=utf-8"
                                    } else {
                                        "application/json; charset=utf-8"
                                    },
                                ))
                                .with_header(header(
                                    "Content-Disposition",
                                    &format!(
                                        "attachment; filename=VTASK-meeting-{}.{}",
                                        value,
                                        if txt { "txt" } else { "json" }
                                    ),
                                )),
                        )?;
                    }
                    Err(e) => send_json(request, Err(e))?,
                }
                continue;
            }
        }
        let result: Result<Value> = (|| match (&method, url) {
            (&Method::Get, "/api/workspace") => {
                store.workspace(query.split('&').any(|p| p == "demo=1"), None)
            }
            (&Method::Post, "/api/workspace/action") => {
                store.workspace_action(&body(&mut request, 1024 * 1024)?)
            }
            (&Method::Post, "/api/assistant/interpret") => {
                groq.start_assistant(&body(&mut request, 8192)?)
            }
            (&Method::Get, "/api/assistant/interpret") => {
                groq.assistant_result(query.strip_prefix("id=").unwrap_or(""))
            }
            (&Method::Post, "/api/groq/settings") => {
                groq.settings(&store, &body(&mut request, 4096)?)
            }
            (&Method::Get, "/api/groq/budget") => store.ai_budget(None),
            (&Method::Post, "/api/groq/budget") => {
                store.ai_budget(Some(&body(&mut request, 4096)?))
            }
            (&Method::Post, "/api/groq/analyze") => {
                let data = body(&mut request, 4096)?;
                if capture.status()["active"]["meeting_id"] == data["meeting_id"] {
                    bail!("Завершите запись этой встречи перед анализом");
                }
                groq.start(&store, &data)
            }
            (&Method::Get, "/api/people") => store.people(),
            (&Method::Get, "/api/meetings") => store.meetings(),
            (&Method::Get, "/api/jobs") => store.jobs(),
            (&Method::Get, "/api/devices") => {
                if !mic_test.active()
                    && !voice_capture.busy()
                    && capture.status()["active"].is_null()
                {
                    inventory = crate::capture::devices(&crate::capture::default_helper())?;
                }
                Ok(json!({"devices":inventory,"selected":microphone}))
            }
            (&Method::Get, "/api/recording/activity") => {
                Ok(json!({"active":capture.status()["active"],"hint":live_voice.status()["hint"]}))
            }
            (&Method::Get, "/api/voice/status") => {
                Ok(json!({"voice_capture":voice_capture.status(),"voice_data":store.voice_snapshot()?}))
            }
            (&Method::Get, "/api/status") => {
                let mut voice_status = voice.status();
                voice_status["interrupted"] = json!(!voice.busy() && store.voice_busy()?);
                Ok(
                    json!({"live_voice":live_voice.status(),"groq":groq.status(),"stage":"workspace","recording":capture.status(),"speech":worker.status(),"models":speech_models(&worker),"microphone":{"selected":microphone,"devices":inventory,"test":mic_test.status()},"live":live.status(),"voice":voice_status,"voice_capture":voice_capture.status(),"voice_data":store.voice_snapshot()?,"final_waiting":final_waiting,"auto_process_error":auto_error,"speaker_recognition":false,"database":"sqlite","binding":address,"free_bytes":fs2::available_space(path.parent().unwrap_or(Path::new("."))).ok()}),
                )
            }
            (&Method::Get, endpoint) if endpoint.starts_with("/api/transcript/") => {
                let mid = endpoint
                    .trim_start_matches("/api/transcript/")
                    .parse::<i64>()?;
                store.transcript(mid)
            }
            (&Method::Get, endpoint) if endpoint.starts_with("/api/audio-timeline/") => {
                let meeting = endpoint.trim_start_matches("/api/audio-timeline/").parse()?;
                let timeline = store.audio_inputs(meeting)?.into_iter().map(|part| json!({
                    "occurrence_id": part["occurrence_id"], "recording_id": part["recording_id"],
                    "start_ms": part["start_ms"], "end_ms": part["end_ms"]
                })).collect();
                Ok(Value::Array(timeline))
            }
            (&Method::Get, endpoint) if endpoint.starts_with("/api/live/meeting/") => {
                let mut live = store.live_snapshot(endpoint.trim_start_matches("/api/live/meeting/").parse()?)?;
                if let Some(session) = live["session_id"].as_str() {
                    let preview = groq.live_preview(session);
                    if !preview.is_null() { live["ai_preview"] = preview; }
                }
                Ok(live)
            }
            (&Method::Get, endpoint) if endpoint.starts_with("/api/meeting/") => {
                let mut export = store.export(endpoint.trim_start_matches("/api/meeting/").parse()?)?;
                if let Some(session) = export["live"]["session_id"].as_str() {
                    let preview = groq.live_preview(session);
                    if !preview.is_null() { export["live"]["ai_preview"] = preview; }
                }
                Ok(export)
            }
            (&Method::Post, "/api/voice/enroll") => {
                if !capture.status()["active"].is_null() || voice_capture.busy() {
                    bail!("Завершите запись перед загрузкой голосового образца");
                }
                let person = query
                    .strip_prefix("person_id=")
                    .context("Выберите участника")?
                    .parse::<i64>()?;
                let confirmed = |name: &'static str| {
                    request
                        .headers()
                        .iter()
                        .any(|h| h.field.equiv(name) && h.value.as_str() == "confirmed")
                };
                if !confirmed("X-Voice-Consent") || !confirmed("X-Voice-Single-Speaker") {
                    bail!("Подтвердите согласие участника и запись одного голоса");
                }
                let mut input = tempfile::NamedTempFile::new()?;
                let copied = std::io::copy(
                    &mut request.as_reader().take(16 * 1024 * 1024 + 1),
                    &mut input,
                )?;
                if copied > 16 * 1024 * 1024 {
                    bail!("Голосовой образец должен быть не больше 16 МБ");
                }
                Ok(
                    json!({"job_id":store.queue_voice_sample(person,input.path(),&voice_root,true,true)?}),
                )
            }
            (&Method::Post, "/api/import") => {
                if !capture.status()["active"].is_null() || voice_capture.busy() {
                    bail!("Дождитесь окончания записи перед импортом");
                }
                let mid = query
                    .strip_prefix("meeting_id=")
                    .context("Выберите встречу")?
                    .parse::<i64>()?;
                let demo: bool =
                    store
                        .0
                        .query_row("SELECT is_demo FROM meetings WHERE id=?1", [mid], |r| {
                            r.get(0)
                        })?;
                if demo {
                    bail!("В деморежиме импорт недоступен");
                }
                let limit = 256 * 1024 * 1024;
                let mut input = tempfile::NamedTempFile::new()?;
                let copied = std::io::copy(&mut request.as_reader().take(limit + 1), &mut input)?;
                if copied > limit {
                    bail!("Для импорта доступны файлы до 256 МБ");
                }
                if hound::WavReader::open(input.path()).is_ok() {
                    store.import_wav(mid, input.path(), &root)
                } else {
                    let output = tempfile::NamedTempFile::with_suffix(".wav")?;
                    let executable = crate::speech::resolve(
                        &std::env::var_os("VTRACKER_FFMPEG_BIN")
                            .map(std::path::PathBuf::from)
                            .unwrap_or_else(|| "ffmpeg".into()),
                    )?;
                    crate::speech::run_command(
                        std::process::Command::new(executable)
                            .args(["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i"])
                            .arg(input.path())
                            .args(["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"])
                            .arg(output.path()),
                        std::time::Duration::from_secs(300),
                    )?;
                    store.import_wav(mid, output.path(), &root)
                }
            }
            (&Method::Post, endpoint) => {
                let data = body(&mut request, 1024 * 1024)?;
                let mid = || data["meeting_id"].as_i64().context("Выберите встречу");
                match endpoint {
                    "/api/voice/capture/start" => {
                        if !capture.status()["active"].is_null()
                            || mic_test.active()
                            || worker.status()["running"] == true
                            || voice.busy()
                            || live.busy()
                            || store.live_busy()?
                            || final_waiting.is_some()
                        {
                            bail!("Дождитесь окончания записи и обработки перед записью голосового образца");
                        }
                        if voice.status()["configured"] != true {
                            bail!("Модель голосовых профилей не настроена");
                        }
                        voice_capture.start(
                            &store,
                            data["person_id"].as_i64().context("Выберите участника")?,
                            data["device_uid"]
                                .as_str()
                                .unwrap_or_else(|| microphone["uid"].as_str().unwrap_or_default()),
                            data["consent"].as_bool().unwrap_or(false),
                        )
                    }
                    "/api/voice/capture/next" => voice_capture.next_phrase(
                        data["draft_id"].as_str().context("Нет голосового образца")?,
                        data["person_id"].as_i64().context("Выберите участника")?,
                        data["phrase_index"].as_u64().context("Укажите номер фразы")?,
                    ),
                    "/api/voice/capture/stop" => voice_capture.stop(
                        data["draft_id"].as_str().context("Выберите образец")?,
                        data["person_id"].as_i64().context("Выберите участника")?,
                    ),
                    "/api/voice/capture/cancel" => {
                        voice_capture.cancel(
                            data["draft_id"].as_str().context("Выберите образец")?,
                            data["person_id"].as_i64().context("Выберите участника")?,
                        )?;
                        Ok(json!({"cancelled":true}))
                    }
                    "/api/voice/capture/accept" => Ok(
                        json!({"job_id":voice_capture.accept(&store,data["draft_id"].as_str().context("Выберите образец")?,data["person_id"].as_i64().context("Выберите участника")?,&voice_root,data["consent"].as_bool().unwrap_or(false),data["single_speaker"].as_bool().unwrap_or(false))?}),
                    ),
                    "/api/voice/source" => store.voice_source_plan(
                        data["model_run_id"]
                            .as_i64()
                            .context("Выберите версию встречи")?,
                        data["speaker_id"].as_str().context("Выберите говорящего")?,
                    ),
                    "/api/voice/from-meeting" => {
                        if !capture.status()["active"].is_null() || voice_capture.busy() {
                            bail!("Завершите запись перед регистрацией голосового профиля");
                        }
                        Ok(
                            json!({"job_id":store.queue_voice_from_meeting(data["person_id"].as_i64().context("Выберите участника")?,data["model_run_id"].as_i64().context("Выберите версию встречи")?,data["speaker_id"].as_str().context("Выберите говорящего")?,data["consent"].as_bool().unwrap_or(false),data["single_speaker"].as_bool().unwrap_or(false))?}),
                        )
                    }
                    "/api/voice/match" => {
                        if !capture.status()["active"].is_null()
                            || voice_capture.busy()
                            || worker.status()["running"] == true
                        {
                            bail!("Дождитесь окончания записи и распознавания");
                        }
                        Ok(
                            json!({"job_id":store.queue_voice_matching(data["model_run_id"].as_i64().context("Выберите версию встречи")?)?}),
                        )
                    }
                    "/api/voice/matching/settings" => store.save_voice_matching_settings(&data),
                    "/api/voice/match/retry" => {
                        if store.0.execute("UPDATE voice_match_jobs SET state='pending',error=NULL WHERE id=?1 AND state='failed'",[data["id"].as_i64().context("Выберите задание")?])?!=1{bail!("Не найдено ошибочное задание сопоставления");}
                        Ok(json!({"queued":true}))
                    }
                    "/api/voice/delete" => {
                        if voice.busy() {
                            bail!("Дождитесь окончания обработки голосового образца");
                        }
                        store.delete_voice(
                            data["person_id"].as_i64().context("Выберите участника")?,
                            &voice_root,
                            data["confirmed"].as_bool().unwrap_or(false),
                        )?;
                        voice_capture.discard_person(
                            data["person_id"].as_i64().context("Выберите участника")?,
                        )?;
                        Ok(json!({"deleted":true}))
                    }
                    "/api/voice/retry" => {
                        store.retry_voice(data["id"].as_i64().context("Выберите задание")?)?;
                        Ok(json!({"queued":true}))
                    }
                    "/api/voice/recover" => {
                        if voice.busy() {
                            bail!("Голосовой обработчик ещё работает");
                        }
                        store
                            .recover_voice(data["confirmed_stopped"].as_bool().unwrap_or(false))?;
                        Ok(json!({"recovered":true}))
                    }
                    "/api/devices/select" => {
                        if mic_test.active()
                            || voice_capture.busy()
                            || !capture.status()["active"].is_null()
                            || voice_capture.busy()
                        {
                            bail!("Завершите запись или проверку перед сменой микрофона");
                        }
                        inventory = crate::capture::devices(&crate::capture::default_helper())?;
                        let uid = data["uid"].as_str().context("Укажите микрофон")?;
                        if !uid.is_empty()
                            && !inventory
                                .as_array()
                                .unwrap()
                                .iter()
                                .any(|d| d["uid"] == uid)
                        {
                            bail!("Микрофон отключён или недоступен. Обновите список");
                        }
                        microphone = json!({"uid":uid});
                        store.0.execute("INSERT INTO workspace_settings(key,data_json) VALUES ('microphone',?1) ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json", [microphone.to_string()])?;
                        Ok(microphone.clone())
                    }
                    "/api/devices/test" => {
                        if !capture.status()["active"].is_null()
                            || voice_capture.busy()
                            || worker.status()["running"] == true
                        {
                            bail!("Сначала завершите запись и обработку");
                        }
                        mic_test.start(
                            &crate::capture::default_helper(),
                            data["uid"]
                                .as_str()
                                .unwrap_or_else(|| microphone["uid"].as_str().unwrap_or_default()),
                            data["seconds"].as_u64().unwrap_or(5),
                        )?;
                        Ok(mic_test.status())
                    }
                    "/api/live/recover" => {
                        if live.busy()
                            || worker.status()["running"] == true
                            || !capture.status()["active"].is_null()
                            || voice_capture.busy()
                            || data["confirmed_stopped"] != true
                        {
                            bail!("Остановите запись и подтвердите, что прежний Live-процесс завершён");
                        }
                        store.recover_live(mid()?)?;
                        Ok(json!({"recovered":true}))
                    }
                    "/api/speech/settings" => {
                        if live.busy() {
                            bail!("Дождитесь завершения Live-обработки");
                        }
                        if worker.status()["running"] == true
                            || !capture.status()["active"].is_null()
                            || voice_capture.busy()
                        {
                            bail!("Завершите запись и обработку перед сменой модели");
                        }
                        let settings = validate_speech_settings(&data)?;
                        store.0.execute("INSERT INTO workspace_settings(key,data_json) VALUES ('speech',?1) ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json", [settings.to_string()])?;
                        if worker.settings["url"] != settings["url"] {
                            worker.api_key.clear();
                        }
                        worker.settings = settings;
                        if let Some(key) = data["api_key"].as_str().filter(|s| !s.is_empty()) {
                            worker.api_key = key.into();
                        }
                        if data["clear_key"] == true {
                            worker.api_key.clear();
                        }
                        Ok(worker.status())
                    }
                    "/api/people" => Ok(
                        json!({"id":store.add_person(data["name"].as_str().unwrap_or_default())?}),
                    ),
                    "/api/meetings" => Ok(
                        json!({"id":store.create_meeting(data["title"].as_str().unwrap_or_default())?}),
                    ),
                    "/api/jobs" => Ok(json!({"id":store.enqueue(mid()?)?})),
                    "/api/jobs/recover" => {
                        if worker.status()["running"] == true || data["confirmed_stopped"] != true {
                            bail!("Подтвердите, что прежний обработчик остановлен");
                        }
                        store.recover_job(data["id"].as_i64().context("Выберите задание")?)?;
                        Ok(json!({"recovered":true}))
                    }
                    "/api/jobs/retry" => {
                        store.retry(data["id"].as_i64().context("Не выбрано задание")?)?;
                        Ok(json!({"queued":true}))
                    }
                    "/api/jobs/cancel" => {
                        worker.cancel(&store, mid()?)?;
                        Ok(json!({"cancelled":true}))
                    }
                    "/api/jobs/run" => {
                        if voice.busy() || store.voice_busy()? {
                            bail!("Дождитесь завершения обработки голосового профиля");
                        }
                        if live.busy() || store.live_busy()? {
                            bail!("Дождитесь завершения Live-обработки; после сбоя используйте восстановление в карточке встречи");
                        }
                        if mic_test.active() || voice_capture.busy() {
                            bail!("Дождитесь окончания проверки микрофона");
                        }
                        if !capture.status()["active"].is_null() || voice_capture.busy() {
                            bail!("Сначала завершите запись. Аудио сохраняется независимо от распознавания");
                        }
                        worker.start_for(path, data["meeting_id"].as_i64())?;
                        Ok(worker.status())
                    }
                    "/api/recording/start" | "/api/recording/continue" => {
                        if voice.busy() || store.voice_busy()? {
                            bail!("Дождитесь завершения обработки голосового профиля");
                        }
                        if live.busy() || final_waiting.is_some() {
                            bail!("Завершается Live-обработка предыдущей записи. Подождите несколько секунд");
                        }
                        let mode = data["processing_mode"]
                            .as_str()
                            .or_else(|| worker.settings["processing_mode"].as_str())
                            .unwrap_or("post");
                        if !["post", "live"].contains(&mode) {
                            bail!("Неизвестный режим обработки");
                        }
                        if mode == "live" && worker.settings["provider"] == "cloud" {
                            bail!("Live пока доступен для локальной модели. Выберите обработку после встречи или локальный режим");
                        }
                        if mic_test.active() || voice_capture.busy() {
                            bail!("Дождитесь окончания проверки микрофона");
                        }
                        if worker.status()["running"] == true {
                            bail!("Дождитесь завершения обработки");
                        }
                        let start_capture = if endpoint == "/api/recording/continue" {
                            crate::capture::CaptureManager::continue_device
                        } else {
                            crate::capture::CaptureManager::start_device
                        };
                        start_capture(
                            &mut capture,
                            &store,
                            mid()?,
                            data["seconds"].as_u64().unwrap_or(7200),
                            data["device_uid"]
                                .as_str()
                                .unwrap_or_else(|| microphone["uid"].as_str().unwrap_or_default()),
                        )?;
                        auto_error = None;
                        if mode == "live" {
                            let status = capture.status();
                            let session =
                                status["active"]["session_id"].as_str().unwrap().to_string();
                            let model = worker.settings["local_model"]
                                .as_str()
                                .filter(|path| !path.is_empty())
                                .map(std::path::PathBuf::from)
                                .or_else(|| {
                                    std::env::var_os("VTRACKER_WHISPER_MODEL")
                                        .map(std::path::PathBuf::from)
                                })
                                .unwrap_or_default();
                            let outcome = store.start_live(
                                mid()?,
                                &session,
                                &model,
                                &std::env::var("VTRACKER_LANGUAGE").unwrap_or_else(|_| "ru".into()),
                            );
                            match outcome {
                                Ok(()) => {
                                    live.attach(session.clone());
                                    if let Err(error) = worker.config() {
                                        store.defer_live(
                                            &session,
                                            &format!(
                                                "Live недоступен: {error}. Запись продолжается"
                                            ),
                                        )?;
                                    }
                                }
                                Err(error) => {
                                    live.last_error = Some(format!(
                                        "Live не запущен: {error}. Запись продолжается"
                                    ))
                                }
                            }
                        }
                        Ok(capture.status())
                    }
                    "/api/recording/stop" => {
                        capture.stop(mid()?)?;
                        Ok(capture.status())
                    }
                    "/api/recording/pause" => {
                        capture.pause(mid()?, false)?;
                        Ok(capture.status())
                    }
                    "/api/recording/resume" => {
                        capture.pause(mid()?, true)?;
                        Ok(capture.status())
                    }
                    "/api/recover" => {
                        if !capture.status()["active"].is_null() || voice_capture.busy() {
                            bail!("Нельзя восстанавливать активную запись");
                        }
                        if data["confirmed_stopped"] != true {
                            bail!("Подтвердите, что предыдущий процесс записи остановлен");
                        }
                        let state: String = store.0.query_row(
                            "SELECT status FROM meetings WHERE id=?1",
                            [mid()?],
                            |r| r.get(0),
                        )?;
                        if state == "recording" {
                            store.interrupt_capture(mid()?)?;
                        } else if state != "failed" {
                            bail!("Восстановление не требуется");
                        }
                        let count = store.recover_audio(mid()?, &root)?
                            + store.recover_capture(mid()?, &root)?;
                        Ok(json!({"recovered":count}))
                    }
                    "/api/speaker/assign" => {
                        let run = data["model_run_id"].as_i64().context("Не выбрана версия")?;
                        let person = match data.get("person_id") {
                            Some(Value::Null) => None,
                            Some(value) => {
                                Some(value.as_i64().context("Участник должен быть числом")?)
                            }
                            None => bail!("person_id обязателен; null снимает назначение"),
                        };
                        let assignment = if let Some(segment) = data["segment_id"].as_i64() {
                            store.assign_segment(run, segment, person)?
                        } else {
                            store.assign_speaker(
                                run,
                                data["speaker_id"].as_str().context("Говорящий не выбран")?,
                                person,
                            )?
                        };
                        Ok(json!({"assignment_id":assignment}))
                    }
                    "/api/segment/edit" => Ok(
                        json!({"edit_id":store.edit_segment(data["model_run_id"].as_i64().context("Не выбрана версия")?,data["segment_id"].as_i64().context("Не выбран фрагмент")?,data["text"].as_str().unwrap_or_default())?}),
                    ),
                    _ => bail!("Неизвестный адрес"),
                }
            }
            _ => bail!("Неизвестный адрес"),
        })();
        send_json(request, result)?;
    }
}

fn validate_speech_settings(data: &Value) -> Result<Value> {
    let provider = data["provider"].as_str().unwrap_or("local");
    if !["local", "cloud"].contains(&provider) {
        bail!("Неизвестный способ распознавания");
    }
    let local = data["local_model"].as_str().unwrap_or_default();
    if !local.is_empty() {
        use std::io::Read;
        let mut file = std::fs::File::open(local).context("Файл модели не найден")?;
        let mut magic = [0; 4];
        file.read_exact(&mut magic)?;
        if magic != *b"lmgg" {
            bail!("Нужна модель Whisper в формате GGML для whisper.cpp");
        }
    }
    let url = data["url"]
        .as_str()
        .unwrap_or("https://api.openai.com/v1/audio/transcriptions");
    let model = data["model"].as_str().unwrap_or("gpt-transcribe");
    let format = data["format"].as_str().unwrap_or("json");
    let mode = data["processing_mode"].as_str().unwrap_or("post");
    if !["post", "live"].contains(&mode) {
        bail!("Неизвестный режим обработки");
    }
    if mode == "live" && provider == "cloud" {
        bail!("Для Live выберите локальную модель или режим после встречи");
    }
    if provider == "cloud" {
        if !url.starts_with("https://")
            || url.contains(['\r', '\n', '@', '#', '?'])
            || url.len() > 2048
        {
            bail!("Укажите полный HTTPS-адрес API без ключа в адресе");
        }
        if model.trim().is_empty() || model.len() > 200 {
            bail!("Укажите имя облачной модели");
        }
        if !["json", "verbose_json"].contains(&format) {
            bail!("Неподдерживаемый формат ответа");
        }
        if data["api_key"]
            .as_str()
            .unwrap_or_default()
            .contains(['\r', '\n'])
        {
            bail!("Некорректный ключ API");
        }
    }
    Ok(
        json!({"provider":provider,"local_model":local,"url":url,"model":model,"format":format,"processing_mode":mode}),
    )
}
fn speech_models(worker: &crate::speech::SpeechWorker) -> Value {
    let root = std::env::var_os("VTRACKER_TOOLS_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".local/share/vtracker")
        })
        .join("models");
    let mut paths = Vec::new();
    if let Ok(entries) = std::fs::read_dir(root) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().is_some_and(|s| s == "bin") && p.is_file() {
                paths.push(p.to_string_lossy().into_owned());
            }
        }
    }
    for p in [
        worker.settings["local_model"].as_str().map(String::from),
        std::env::var("VTRACKER_WHISPER_MODEL").ok(),
    ]
    .into_iter()
    .flatten()
    {
        if !p.is_empty() && !paths.contains(&p) {
            paths.push(p);
        }
    }
    paths.sort();
    json!(paths)
}
