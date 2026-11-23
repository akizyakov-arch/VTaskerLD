use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashSet};

const EVENT_PERIODS: &[(&str, &[(&str, &str)])] = &[
    (
        "Бриф и планирование",
        &[
            ("brief", "Бриф и постановка целей"),
            ("concept", "Концепция"),
            ("budget", "Смета и согласование бюджета"),
            ("venue", "Подбор и бронирование площадки"),
            ("contracting", "Подбор команды и договоры с подрядчиками"),
        ],
    ),
    (
        "Программа и работа с гостями",
        &[
            ("program", "Программа и сценарий"),
            ("talent", "Подготовка ведущих, артистов и спикеров"),
            ("promotion", "Анонс и продвижение"),
            ("invitations", "Приглашения, билеты и регистрация"),
            ("guest-services", "Рассадка, трансферы и размещение гостей"),
            ("catering", "Подготовка кейтеринга"),
        ],
    ),
    (
        "Площадка, декор и техническая подготовка",
        &[
            ("site-survey", "Осмотр площадки и замеры"),
            ("layout", "План зонирования и расстановки"),
            ("decor-design", "Сценография и согласование эскизов декора"),
            ("procurement", "Закупка материалов и аренда оборудования"),
            ("production", "Изготовление"),
            ("floristry", "Подготовка флористики"),
            ("technical-plan", "План звука, света, видео и трансляции"),
            (
                "site-access",
                "Пропуска, безопасность и согласования с площадкой",
            ),
        ],
    ),
    (
        "Монтаж и готовность к открытию",
        &[
            ("delivery", "Доставка"),
            ("setup", "Монтаж"),
            (
                "technical-check",
                "Настройка оборудования и технические проверки",
            ),
            ("rehearsal", "Репетиция и инструктаж команды"),
            ("venue-acceptance", "Проверка готовности площадки"),
        ],
    ),
    (
        "День мероприятия",
        &[
            ("doors", "Открытие площадки и встреча гостей"),
            ("event", "Проведение мероприятия"),
            ("media", "Фото- и видеосъёмка, трансляция"),
        ],
    ),
    (
        "Демонтаж и закрытие",
        &[
            ("teardown", "Демонтаж"),
            ("returns", "Возврат аренды и сдача площадки"),
            ("deliverables", "Передача фото, видео и материалов"),
            ("settlement", "Закрывающие документы и расчёты"),
            ("debrief", "Обратная связь и разбор итогов"),
        ],
    ),
];

const STARTER_PERIODS: &[(&str, &[(&str, &str)])] = &[
    (
        "universal",
        &[
            ("planning", "Планирование"),
            ("preparation", "Подготовка"),
            ("execution", "Выполнение работ"),
            ("handover", "Сдача результата"),
        ],
    ),
    (
        "construction",
        &[
            ("design", "Проектирование"),
            ("site", "Подготовка площадки"),
            ("procurement", "Закупки и поставки"),
            ("building", "Строительно-монтажные работы"),
            ("testing", "Испытания"),
            ("handover", "Приёмка и передача"),
        ],
    ),
    (
        "it",
        &[
            ("requirements", "Сбор требований"),
            ("design", "Проектирование"),
            ("development", "Разработка"),
            ("testing", "Тестирование"),
            ("release", "Выпуск"),
        ],
    ),
    (
        "architecture_design",
        &[
            ("survey", "Обмеры и исходные данные"),
            ("concept", "Эскизная концепция"),
            ("documentation", "Рабочая документация"),
            ("oversight", "Авторский надзор"),
        ],
    ),
    (
        "creative_studios",
        &[
            ("brief", "Брифинг"),
            ("concept", "Разработка концепции"),
            ("production", "Производство материалов"),
            ("review", "Согласование"),
        ],
    ),
    (
        "marketing",
        &[
            ("research", "Исследование аудитории"),
            ("plan", "Медиапланирование"),
            ("launch", "Запуск кампании"),
            ("report", "Оценка результатов"),
        ],
    ),
    (
        "sales",
        &[
            ("qualification", "Квалификация клиента"),
            ("proposal", "Коммерческое предложение"),
            ("negotiation", "Переговоры"),
            ("contract", "Заключение договора"),
        ],
    ),
    (
        "manufacturing",
        &[
            ("engineering", "Технологическая подготовка"),
            ("supply", "Обеспечение материалами"),
            ("production", "Изготовление"),
            ("quality", "Контроль качества"),
            ("shipping", "Отгрузка"),
        ],
    ),
    (
        "project_management",
        &[
            ("initiation", "Инициация проекта"),
            ("planning", "Планирование проекта"),
            ("implementation", "Реализация"),
            ("closure", "Закрытие проекта"),
        ],
    ),
    (
        "consulting",
        &[
            ("discovery", "Диагностика"),
            ("analysis", "Анализ"),
            ("recommendations", "Разработка рекомендаций"),
            ("handover", "Передача результатов"),
        ],
    ),
    (
        "logistics",
        &[
            ("routing", "Планирование маршрута"),
            ("pickup", "Забор груза"),
            ("transport", "Перевозка"),
            ("delivery", "Передача получателю"),
        ],
    ),
    (
        "retail",
        &[
            ("assortment", "Планирование ассортимента"),
            ("supply", "Поставка товара"),
            ("launch", "Запуск продаж"),
            ("review", "Анализ продаж"),
        ],
    ),
    (
        "finance",
        &[
            ("inputs", "Сбор исходных данных"),
            ("reconciliation", "Сверка данных"),
            ("reporting", "Подготовка отчётности"),
            ("approval", "Согласование отчётности"),
        ],
    ),
    (
        "legal",
        &[
            ("facts", "Сбор материалов"),
            ("review", "Правовой анализ"),
            ("documents", "Подготовка документов"),
            ("approval", "Согласование документов"),
        ],
    ),
    (
        "hr",
        &[
            ("profile", "Описание вакансии"),
            ("search", "Поиск кандидатов"),
            ("interviews", "Собеседования"),
            ("onboarding", "Адаптация сотрудника"),
        ],
    ),
    (
        "real_estate",
        &[
            ("inspection", "Обследование объекта"),
            ("documents", "Подготовка документации"),
            ("contract", "Оформление сделки"),
            ("handover", "Передача объекта"),
        ],
    ),
    (
        "horeca",
        &[
            ("preparation", "Подготовка к открытию"),
            ("supply", "Закупки и поставки"),
            ("launch", "Открытие"),
            ("review", "Оценка сервиса"),
        ],
    ),
    (
        "healthcare",
        &[
            ("planning", "Планирование работы"),
            ("coordination", "Согласование ресурсов"),
            ("implementation", "Внедрение"),
            ("quality", "Оценка качества"),
        ],
    ),
    (
        "education",
        &[
            ("curriculum", "Разработка программы"),
            ("materials", "Подготовка учебных материалов"),
            ("delivery", "Проведение обучения"),
            ("assessment", "Оценка результатов"),
        ],
    ),
    (
        "media",
        &[
            ("preproduction", "Подготовка съёмок"),
            ("shooting", "Съёмка"),
            ("postproduction", "Постпродакшен"),
            ("release", "Публикация"),
        ],
    ),
    (
        "government",
        &[
            ("planning", "Подготовка плана"),
            ("approval", "Согласование"),
            ("implementation", "Реализация мероприятий"),
            ("report", "Подготовка отчёта"),
        ],
    ),
    (
        "research",
        &[
            ("plan", "Планирование исследования"),
            ("collect", "Сбор данных"),
            ("analysis", "Анализ результатов"),
            ("publication", "Подготовка публикации"),
        ],
    ),
    (
        "energy",
        &[
            ("survey", "Обследование"),
            ("design", "Инженерное проектирование"),
            ("installation", "Монтаж оборудования"),
            ("commissioning", "Пусконаладка"),
        ],
    ),
    (
        "agriculture",
        &[
            ("plan", "Планирование сезона"),
            ("preparation", "Подготовительные работы"),
            ("fieldwork", "Полевые работы"),
            ("harvest", "Сбор урожая"),
        ],
    ),
];

fn catalog_key(demo: bool) -> &'static str {
    if demo {
        "demo_work_period_catalog"
    } else {
        "work_period_catalog"
    }
}

fn company_entries(db: &Connection, demo: bool) -> Result<Vec<Value>> {
    let raw: Option<String> = db
        .query_row(
            "SELECT data_json FROM workspace_settings WHERE key=?1",
            [catalog_key(demo)],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|data| serde_json::from_str(&data).map_err(Into::into))
        .unwrap_or_else(|| Ok(Vec::new()))
}

fn default_entries(db: &Connection, demo: bool) -> Result<Vec<Value>> {
    let mut entries = company_entries(db, demo)?;
    for &(phase, periods) in EVENT_PERIODS {
        for &(slug, title) in periods {
            entries.push(json!({
                "id": format!("builtin:events:{slug}"), "title": title,
                "industry_id": "events", "built_in": true, "phase": phase
            }));
        }
    }
    for &(industry, templates) in STARTER_PERIODS {
        for &(slug, title) in templates {
            entries.push(json!({
                "id": format!("builtin:{industry}:{slug}"), "title": title,
                "industry_id": industry, "built_in": true
            }));
        }
    }
    Ok(entries)
}

type Lists = BTreeMap<String, Vec<Value>>;

fn lists_key(demo: bool) -> &'static str {
    if demo {
        "demo_work_period_lists"
    } else {
        "work_period_lists"
    }
}

fn lists(db: &Connection, demo: bool) -> Result<Lists> {
    let raw: Option<String> = db
        .query_row(
            "SELECT data_json FROM workspace_settings WHERE key=?1",
            [lists_key(demo)],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|text| serde_json::from_str(&text).map_err(Into::into))
        .unwrap_or_else(|| Ok(Lists::new()))
}

fn write_lists(db: &Connection, demo: bool, lists: &Lists) -> Result<()> {
    db.execute(
        "INSERT INTO workspace_settings(key,data_json) VALUES (?1,?2)
         ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",
        params![lists_key(demo), serde_json::to_string(lists)?],
    )?;
    Ok(())
}

pub(crate) fn list(db: &Connection, demo: bool) -> Result<Vec<Value>> {
    let overrides = lists(db, demo)?;
    let mut entries = default_entries(db, demo)?;
    entries
        .retain(|entry| !overrides.contains_key(entry["industry_id"].as_str().unwrap_or_default()));
    for (scope, rows) in overrides {
        if !scope.starts_with("events/") {
            entries.extend(rows);
        }
    }
    Ok(entries)
}

fn event_defaults(kind: &str) -> Vec<Value> {
    let stages: &[(&str, &str)] = match kind {
        "decor" => &[
            ("brief", "Брифинг"),
            ("concept", "Концепция"),
            ("design", "Замеры, эскизы и визуализация"),
            ("budget", "Смета и согласование"),
            ("procurement", "Закупки"),
            ("production", "Производство"),
            ("setup", "Доставка и монтаж"),
            ("teardown", "Демонтаж и закрытие"),
        ],
        "organization" => &[
            ("brief", "Бриф и постановка целей"),
            ("concept", "Концепция, формат и программа"),
            ("budget", "Смета и согласование бюджета"),
            ("venue", "Подбор и бронирование площадки"),
            ("vendors", "Команда и договоры с подрядчиками"),
            ("guests", "Приглашения и регистрация гостей"),
            ("services", "Трансферы, рассадка и кейтеринг"),
            ("technical", "Технический план и подготовка площадки"),
            ("rehearsal", "Репетиция и проверка готовности"),
            ("event", "Проведение мероприятия"),
            ("closure", "Расчёты, материалы и разбор итогов"),
        ],
        _ => return vec![],
    };
    stages
        .iter()
        .map(|&(id, title)| {
            json!({
                "id": format!("builtin:events:{kind}:{id}"),
                "title": title, "industry_id": "events", "built_in": true
            })
        })
        .collect()
}

pub(crate) fn event_lists(db: &Connection, demo: bool) -> Result<Value> {
    let mut overrides = lists(db, demo)?;
    let mut result = serde_json::Map::new();
    for kind in ["decor", "organization"] {
        let entries = overrides
            .remove(&format!("events/{kind}"))
            .unwrap_or_else(|| event_defaults(kind));
        result.insert(kind.to_owned(), json!(entries));
    }
    Ok(Value::Object(result))
}

fn checked_industry(db: &Connection, input: &Value) -> Result<String> {
    let industry = crate::glossary::normalize_industry(
        input["industry_id"]
            .as_str()
            .context("Выберите отрасль для этапа")?,
    );
    if industry != "universal" && !crate::glossary::has_industry(db, industry)? {
        bail!("Выберите действующую отрасль для этапа");
    }
    Ok(industry.to_owned())
}

fn identity(rows: &[Value]) -> Vec<Value> {
    rows.iter()
        .map(|row| json!({"id": row["id"], "title": row["title"]}))
        .collect()
}

pub(crate) fn save_list(db: &Connection, demo: bool, input: &Value) -> Result<Value> {
    let industry = checked_industry(db, input)?;
    let mut overrides = lists(db, demo)?;
    let (scope, current) = match input.get("project_type") {
        None => {
            let rows = list(db, demo)?
                .into_iter()
                .filter(|row| row["industry_id"] == industry)
                .collect();
            (industry.clone(), rows)
        }
        Some(value) => {
            let kind = value.as_str().context("Выберите тип проекта")?;
            if industry != "events" || !["decor", "organization"].contains(&kind) {
                bail!("Неизвестный тип проекта");
            }
            let scope = format!("events/{kind}");
            let rows = overrides
                .get(&scope)
                .cloned()
                .unwrap_or_else(|| event_defaults(kind));
            (scope, rows)
        }
    };
    let items = input["items"].as_array().context("Укажите этапы списка")?;
    if items.len() > 250 {
        bail!("В одном списке может быть не больше 250 этапов");
    }
    let mut ids = HashSet::new();
    let mut titles = HashSet::new();
    let mut updated = Vec::with_capacity(items.len());
    for item in items {
        let id = item["id"]
            .as_str()
            .context("Не указан идентификатор этапа")?;
        let title = item["title"].as_str().unwrap_or_default().trim();
        if title.is_empty() || title.chars().count() > 250 {
            bail!("Укажите название этапа длиной до 250 символов");
        }
        if !ids.insert(id) || !titles.insert(title_key(title)) {
            bail!("В списке есть повторяющийся этап");
        }
        let mut entry = if let Some(original) = current.iter().find(|row| row["id"] == id) {
            original.clone()
        } else {
            if !id.strip_prefix("custom:").is_some_and(|suffix| {
                suffix.len() == 32 && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
            }) {
                bail!("Не удалось сопоставить этап. Обновите справочник");
            }
            json!({"id":id, "industry_id":industry, "built_in":false})
        };
        // Once a list is edited, display it in the order chosen by the user.
        entry.as_object_mut().unwrap().remove("phase");
        entry["title"] = json!(title);
        updated.push(entry);
    }
    let latest = identity(&current);
    if latest == identity(&updated) {
        return Ok(json!({"saved":true}));
    }
    if input["base"].as_array() != Some(&latest) {
        bail!("Список уже изменился. Откройте редактор заново");
    }
    overrides.insert(scope, updated);
    write_lists(db, demo, &overrides)?;
    Ok(json!({"saved":true}))
}

fn title_key(title: &str) -> String {
    title
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
        .replace('ё', "е")
}

pub(crate) fn save(db: &Connection, demo: bool, input: &Value) -> Result<Value> {
    let title = input["title"].as_str().unwrap_or_default().trim();
    if title.is_empty() {
        bail!("Укажите название этапа работ");
    }
    let industry = checked_industry(db, input)?;
    let entries = list(db, demo)?;
    let previous = if let Some(id) = input.get("id") {
        Some(
            entries
                .iter()
                .find(|row| row["id"] == *id && row["built_in"] == false)
                .context("Сохранённый этап не найден")?,
        )
    } else {
        None
    };
    let id = if let Some(row) = previous {
        row["id"]
            .as_str()
            .context("Некорректный сохранённый этап")?
            .to_owned()
    } else {
        db.query_row(
            "SELECT 'custom:' || lower(hex(randomblob(16)))",
            [],
            |row| row.get(0),
        )?
    };
    let key = title_key(title);
    let same_name = previous.is_some_and(|row| {
        row["industry_id"] == industry
            && row["title"]
                .as_str()
                .is_some_and(|name| title_key(name) == key)
    });
    if !same_name
        && entries.iter().any(|row| {
            row["id"] != id
                && row["industry_id"] == industry
                && row["title"]
                    .as_str()
                    .is_some_and(|name| title_key(name) == key)
        })
    {
        bail!("Этап с таким названием уже есть в выбранной отрасли");
    }
    let entry = json!({"id":id, "title":title, "industry_id":industry, "built_in":false});
    let mut overrides = lists(db, demo)?;
    let mut current: Vec<_> = entries
        .iter()
        .filter(|row| row["industry_id"] == industry)
        .cloned()
        .collect();
    if let Some(index) = current.iter().position(|row| row["id"] == id) {
        current[index] = entry.clone();
    } else {
        current.push(entry.clone());
    }
    overrides.insert(industry.clone(), current);
    if let Some(old_industry) = previous
        .and_then(|row| row["industry_id"].as_str())
        .filter(|old| *old != industry)
    {
        let rows = entries
            .iter()
            .filter(|row| row["industry_id"] == old_industry && row["id"] != id)
            .cloned()
            .collect();
        overrides.insert(old_industry.to_owned(), rows);
    }
    write_lists(db, demo, &overrides)?;
    Ok(entry)
}
