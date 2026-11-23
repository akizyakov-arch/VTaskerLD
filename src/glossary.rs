//! Company-wide terms shared by the desktop client and the meeting analysis pipeline.
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
mod transfer;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
pub(crate) use transfer::{export, import};

fn field(value: &Value, max: usize, required: bool) -> Result<&str> {
    let text = match value {
        Value::Null if !required => "",
        Value::String(text) => text.trim(),
        _ => bail!("Некорректное поле справочника"),
    };
    if text.chars().count() > max || (required && words(text).is_empty()) {
        bail!("Заполните термин и варианты. Максимальная длина поля — {max} символов");
    }
    Ok(text)
}

fn language(value: &Value) -> Result<String> {
    let text = field(value, 35, false)?.to_ascii_lowercase();
    if !text.is_empty()
        && !text.split('-').all(|part| {
            !part.is_empty() && part.len() <= 8 && part.bytes().all(|c| c.is_ascii_alphanumeric())
        })
    {
        bail!("Укажите код языка, например ru, en или pt-BR");
    }
    Ok(text)
}

fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(|word| word.to_lowercase().replace('ё', "е"))
        .collect()
}

pub(crate) fn list(db: &Connection) -> Result<Vec<Value>> {
    let mut query = db.prepare("SELECT id,revision,data_json FROM company_terms ORDER BY id")?;
    let rows = query.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    rows.map(|row| {
        let (id, revision, raw) = row?;
        let mut value: Value = serde_json::from_str(&raw)?;
        value["id"] = json!(id);
        value["revision"] = json!(revision);
        Ok(value)
    })
    .collect()
}

fn industry_packs() -> &'static Value {
    static PACKS: std::sync::LazyLock<Value> = std::sync::LazyLock::new(|| {
        serde_json::from_str(include_str!("industry-packs.json"))
            .expect("Built-in industry packs must be valid JSON")
    });
    &PACKS
}

struct EmbeddedPack {
    id: &'static str,
    raw: &'static str,
    parsed: std::sync::OnceLock<Value>,
}

macro_rules! embedded_packs {
    ($($id:ident),+ $(,)?) => {
        static EMBEDDED_PACKS: [EmbeddedPack; [$(stringify!($id)),+].len()] = [$(EmbeddedPack {
            id: stringify!($id),
            raw: include_str!(concat!("industry-packs/", stringify!($id), ".json")),
            parsed: std::sync::OnceLock::new(),
        }),+];
    };
}

embedded_packs!(
    universal,
    it,
    construction,
    events,
    architecture_design,
    creative_studios,
    marketing,
    sales,
    manufacturing,
    project_management,
    consulting,
    logistics,
    retail,
    finance,
    legal,
    hr,
    real_estate,
    horeca,
    healthcare,
    education,
    media,
    government,
    research,
    energy,
    agriculture
);

fn embedded_pack(id: &str) -> Option<&'static EmbeddedPack> {
    EMBEDDED_PACKS.iter().find(|pack| pack.id == id)
}

fn embedded_terms(id: &str) -> Option<&'static Value> {
    embedded_pack(id).map(|pack| {
        pack.parsed.get_or_init(|| {
            serde_json::from_str(pack.raw).expect("Built-in industry package must be valid JSON")
        })
    })
}

pub(crate) fn industry_catalog(db: &Connection) -> Result<Vec<Value>> {
    let mut options = industry_packs()["catalog"].as_array().unwrap().clone();
    let mut statement = db.prepare(
        "SELECT substr(key, length('industry_package:')+1), json_extract(data_json,'$.title')
         FROM workspace_settings WHERE key GLOB 'industry_package:*' ORDER BY key",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    for row in rows {
        let (id, title) = row?;
        if !options.iter().any(|option| option["id"] == id) {
            options.push(json!({"id":id,"title":title}));
        }
    }
    Ok(options)
}

fn built_in_specializations(industry: &str) -> &'static [Value] {
    static CATALOG: std::sync::LazyLock<Value> = std::sync::LazyLock::new(|| {
        serde_json::from_str(include_str!("industry-specializations.json"))
            .expect("Built-in specializations must be valid JSON")
    });
    CATALOG[industry].as_array().map_or(&[], Vec::as_slice)
}

pub(crate) fn parent_industry(scope: &str) -> &str {
    normalize_industry(scope.split_once('/').map_or(scope, |(parent, _)| parent))
}

pub(crate) fn valid_specialization_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
}

fn specialization_ids(entry: &Value, industry: &str) -> Vec<String> {
    let tagged = entry["specialization_ids"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if !tagged.is_empty() {
        return tagged;
    }
    let number = entry["source_id"]
        .as_str()
        .and_then(|id| id.rsplit_once('.'))
        .and_then(|(_, id)| id.parse::<u64>().ok());
    // Built-in tags apply to the supplied package records and legacy grouping sections.
    let built_in_source = entry["source_id"].as_str().is_some_and(|id| {
        embedded_terms(industry)
            .and_then(Value::as_array)
            .is_some_and(|entries| entries.iter().any(|entry| entry["source_id"] == id))
    });
    built_in_specializations(industry)
        .iter()
        .filter(|spec| {
            (built_in_source
                && number.is_some_and(|number| {
                    spec["pack_terms"]
                        .as_array()
                        .is_some_and(|ids| ids.iter().any(|id| id.as_u64() == Some(number)))
                }))
                || spec["sections"]
                    .as_array()
                    .is_some_and(|sections| sections.contains(&entry["section"]))
        })
        .filter_map(|spec| spec["id"].as_str())
        .map(str::to_owned)
        .collect()
}

pub(crate) fn specialization_catalog(db: &Connection) -> Result<Vec<Value>> {
    let mut statement = db.prepare(
        "SELECT DISTINCT substr(p.key,length('industry_package:')+1),t.value
         FROM workspace_settings p
         JOIN json_each(p.data_json,'$.entries') e
         JOIN json_each(e.value,'$.specialization_ids') t
         WHERE p.key GLOB 'industry_package:*' ORDER BY 1,2",
    )?;
    let mut imported: HashMap<String, Vec<String>> = HashMap::new();
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        imported.entry(row.get(0)?).or_default().push(row.get(1)?);
    }
    let mut catalog = Vec::new();
    for option in industry_catalog(db)? {
        let industry = option["id"].as_str().unwrap();
        let mut groups = built_in_specializations(industry)
            .iter()
            .map(|spec| {
                (
                    spec["id"].as_str().unwrap().to_owned(),
                    spec["title"].as_str().unwrap().to_owned(),
                )
            })
            .collect::<Vec<_>>();
        for id in imported.remove(industry).unwrap_or_default() {
            if !groups.iter().any(|(known, _)| known == &id) {
                groups.push((id.clone(), id.replace('_', " ")));
            }
        }
        for (id, title) in groups {
            catalog.push(
                json!({"id":format!("{industry}/{id}"),"industry_id":industry,"title":title}),
            );
        }
    }
    Ok(catalog)
}

pub(crate) fn has_dictionary_scope(db: &Connection, scope: &str) -> Result<bool> {
    if scope.contains('/') {
        Ok(specialization_catalog(db)?
            .iter()
            .any(|option| option["id"] == scope))
    } else {
        has_industry(db, scope)
    }
}

pub(crate) fn normalize_industry(industry: &str) -> &str {
    if industry == "decor" {
        "events"
    } else {
        industry
    }
}

pub(crate) fn has_industry(db: &Connection, industry: &str) -> Result<bool> {
    let industry = normalize_industry(industry);
    Ok(embedded_pack(industry).is_some() || loaded_package(db, industry)?.is_some())
}

fn loaded_package(db: &Connection, id: &str) -> Result<Option<Value>> {
    let raw: Option<String> = db
        .query_row(
            "SELECT data_json FROM workspace_settings WHERE key=?1",
            [format!("industry_package:{id}")],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|raw| serde_json::from_str(&raw).map_err(Into::into))
        .transpose()
}

fn package(db: &Connection, id: &str) -> Result<Option<Value>> {
    let loaded = loaded_package(db, id)?;
    let builtin = embedded_terms(id);
    if let Some(mut document) = loaded {
        if let Some(entries) = document["entries"].as_array_mut() {
            let existing: HashSet<_> = entries
                .iter()
                .filter_map(|entry| entry["source_id"].as_str().map(str::to_owned))
                .collect();
            entries.extend(
                builtin
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|entry| {
                        entry["source_id"]
                            .as_str()
                            .is_some_and(|source| !existing.contains(source))
                    })
                    .cloned(),
            );
        }
        return Ok(Some(document));
    }
    let catalog = industry_packs();
    let option = catalog["catalog"]
        .as_array()
        .unwrap()
        .iter()
        .find(|option| option["id"] == id);
    Ok(option.map(|option| {
        json!({
            "title":option["title"],"revision":catalog["revision"],"entries":builtin,
        })
    }))
}

fn starter_vocabulary() -> &'static Value {
    static VOCABULARY: std::sync::LazyLock<Value> = std::sync::LazyLock::new(|| {
        serde_json::from_str(include_str!("industry-glossaries.json"))
            .expect("Built-in industry vocabulary must be valid JSON")
    });
    &VOCABULARY
}

pub(crate) fn browse(db: &Connection) -> Result<Value> {
    let mut sections = industry_catalog(db)?;
    let starter = starter_vocabulary();
    let mut terms = Vec::new();
    let mut legacy_id = -1;
    for section in &mut sections {
        let industry = section["id"].as_str().unwrap().to_owned();
        let original = starter[&industry].as_array().into_iter().flatten();
        let shared = (industry == "universal")
            .then(|| starter["common"].as_array())
            .flatten()
            .into_iter()
            .flatten();
        let mut entries = shared
            .chain(original)
            .map(|entry| {
                let mut entry = entry.clone();
                entry["id"] = json!(legacy_id);
                entry["revision"] = json!(0);
                legacy_id -= 1;
                entry
            })
            .collect::<Vec<_>>();
        if let Some(document) = package(db, &industry)? {
            entries.extend(
                document["entries"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .cloned(),
            );
        }
        section["count"] = json!(entries.len());
        for mut term in entries {
            term["industry_id"] = json!(industry);
            terms.push(term);
        }
    }
    Ok(json!({"industries":sections,"terms":terms}))
}

pub(crate) fn industry_terms(db: &Connection, industry: &str) -> Result<Vec<Value>> {
    industry_terms_for(db, &[industry.to_owned()])
}

pub(crate) fn industry_terms_for(db: &Connection, industries: &[String]) -> Result<Vec<Value>> {
    let vocabulary = starter_vocabulary();
    let mut parents = Vec::new();
    for scope in industries {
        let parent = parent_industry(scope);
        if parent != "universal" && !parents.contains(&parent) {
            parents.push(parent);
        }
    }
    parents.push("universal");
    let mut terms = Vec::new();
    let mut append_legacy = |entry: &Value| {
        let mut entry = entry.clone();
        entry["id"] = json!(-(terms.len() as i64) - 1);
        entry["revision"] = json!(0);
        terms.push(entry);
    };
    for entry in vocabulary["common"].as_array().into_iter().flatten() {
        append_legacy(entry);
    }
    let mut packaged_terms = Vec::new();
    for parent in parents {
        let selected = industries
            .iter()
            .filter_map(|scope| {
                let (industry, specialization) = scope.split_once('/')?;
                (industry == parent).then_some(specialization)
            })
            .collect::<HashSet<_>>();
        let full = selected.is_empty()
            || industries
                .iter()
                .any(|scope| normalize_industry(scope) == parent);
        let included = |entry: &Value| {
            if full {
                return true;
            }
            let tags = specialization_ids(entry, parent);
            tags.is_empty() || tags.iter().any(|tag| selected.contains(tag.as_str()))
        };
        let legacy = (parent != "universal" || industries.iter().any(|scope| scope == "universal"))
            .then(|| vocabulary[parent].as_array())
            .flatten();
        for entry in legacy.into_iter().flatten().filter(|entry| included(entry)) {
            append_legacy(entry);
        }
        if let Some(document) = package(db, parent)? {
            packaged_terms.extend(
                document["entries"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|entry| included(entry))
                    .cloned(),
            );
        }
    }
    terms.extend(packaged_terms);
    Ok(terms)
}

pub(crate) fn effective_terms(company: &[Value], industry: &[Value]) -> Vec<Value> {
    let mut merged = company.to_vec();
    let mut claimed = company
        .iter()
        .flat_map(spellings_of)
        .map(|(text, context)| (words(text), words(context)))
        .collect::<HashSet<_>>();

    for starter in industry {
        if starter["lookup_only"] == true {
            merged.push(starter.clone());
            continue;
        }
        let spelling = words(starter["term"].as_str().unwrap_or_default());
        let same_term = merged
            .iter_mut()
            .find(|entry| words(entry["term"].as_str().unwrap_or_default()) == spelling);
        if same_term.is_none() && !claimed.insert((spelling, Vec::new())) {
            continue;
        }
        let variants: Vec<Value> = starter["variants"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|variant| {
                claimed.insert((
                    words(variant["text"].as_str().unwrap_or_default()),
                    words(variant["context"].as_str().unwrap_or_default()),
                ))
            })
            .cloned()
            .collect();
        if let Some(entry) = same_term {
            if let Some(aliases) = entry["variants"].as_array_mut() {
                aliases.extend(variants);
            }
            if entry["section"].as_str().unwrap_or_default().is_empty() {
                entry["section"] = starter["section"].clone();
            }
        } else {
            let mut entry = starter.clone();
            entry["variants"] = json!(variants);
            merged.push(entry);
        }
    }
    merged
}

pub(crate) fn active_terms(db: &Connection, industry: &str) -> Result<Vec<Value>> {
    Ok(effective_terms(&list(db)?, &industry_terms(db, industry)?))
}

fn validated_term(data: &Value) -> Result<Value> {
    let term = field(&data["term"], 120, true)?;
    let term_language = language(&data["language"])?;
    let section = field(&data["section"], 80, false)?;
    let definition = field(&data["definition"], 600, false)?;
    let variants = data["variants"]
        .as_array()
        .filter(|items| items.len() <= 30)
        .context("Можно указать до тридцати вариантов термина")?;
    let mut spellings = HashSet::from([(words(term), Vec::new())]);
    let mut cleaned = Vec::with_capacity(variants.len());
    for variant in variants {
        let text = field(&variant["text"], 120, true)?;
        let context = field(&variant["context"], 120, false)?;
        if !context.is_empty() && !(1..=5).contains(&words(context).len()) {
            bail!("Укажите от одного до пяти слов для контекста");
        }
        if !spellings.insert((words(text), words(context))) {
            bail!("«{text}» уже указан в этой записи");
        }
        let mut alias = json!({"text":text,"language":language(&variant["language"])?});
        if !context.is_empty() {
            alias["context"] = json!(context);
        }
        cleaned.push(alias);
    }
    let mut entry =
        json!({"term":term,"language":term_language,"section":section,"variants":cleaned});
    if !definition.is_empty() {
        entry["definition"] = json!(definition);
    }
    Ok(entry)
}

pub(crate) fn save(db: &Connection, request: &Value) -> Result<Value> {
    let entry = validated_term(&request["data"])?;
    let spellings: HashSet<_> = spelling_keys(&entry).collect();
    let id = if request["id"].is_null() {
        None
    } else {
        Some(
            request["id"]
                .as_i64()
                .filter(|id| *id > 0)
                .context("Некорректная запись справочника")?,
        )
    };
    for existing in list(db)?.iter().filter(|entry| entry["id"].as_i64() != id) {
        if spelling_keys(existing).any(|key| spellings.contains(&key)) {
            let existing = existing["term"].as_str().unwrap_or_default();
            bail!("Такое написание уже есть в записи «{existing}». Откройте её в справочнике");
        }
    }
    let raw = entry.to_string();
    if let Some(id) = id {
        let revision = request["revision"]
            .as_i64()
            .context("Обновите справочник и повторите")?;
        if db.execute(
            "UPDATE company_terms SET data_json=?1,revision=revision+1 WHERE id=?2 AND revision=?3",
            params![raw, id, revision],
        )? != 1
        {
            bail!("Запись изменилась. Откройте её заново");
        }
        Ok(json!({"id":id,"revision":revision+1}))
    } else {
        db.execute("INSERT INTO company_terms(data_json) VALUES (?1)", [raw])?;
        Ok(json!({"id":db.last_insert_rowid(),"revision":1}))
    }
}

pub(crate) fn remove(db: &Connection, request: &Value) -> Result<Value> {
    let id = request["id"]
        .as_i64()
        .context("Выберите запись справочника")?;
    let revision = request["revision"]
        .as_i64()
        .context("Обновите справочник и повторите")?;
    if db.execute(
        "DELETE FROM company_terms WHERE id=?1 AND revision=?2",
        params![id, revision],
    )? != 1
    {
        bail!("Запись изменилась. Откройте её заново");
    }
    Ok(json!({"deleted":true}))
}

pub(crate) fn proposals(db: &Connection, vocabulary: &[Value]) -> Result<Vec<Value>> {
    let mut statement =
        db.prepare("SELECT spelling,status,term_id,reviewed_at FROM term_reviews")?;
    let reviews: HashMap<String, (String, Option<i64>, String)> = statement
        .query_map([], |row| {
            Ok((row.get(0)?, (row.get(1)?, row.get(2)?, row.get(3)?)))
        })?
        .collect::<rusqlite::Result<_>>()?;

    let known: HashSet<_> = vocabulary
        .iter()
        .flat_map(|entry| entry["term"].as_str().into_iter().chain(variants_of(entry)))
        .map(|text| words(text).join(" "))
        .collect();
    let mut statement = db.prepare(
        "SELECT a.meeting_id, json_extract(f.value,'$.text'), json_extract(f.value,'$.source.quote')
         FROM meeting_analyses a JOIN meetings m ON m.id=a.meeting_id
         JOIN json_each(a.result_json,'$.findings') f
         WHERE m.is_demo=0 AND a.state='completed' AND instr(a.result_json, '\"unclear_term\"') > 0
           AND json_extract(f.value,'$.kind')='unclear_term'
         ORDER BY a.id DESC",
    )?;
    let mut rows = statement.query([])?;
    let mut indexes = HashMap::<String, usize>::new();
    let mut results = Vec::<Value>::new();
    let mut sources = HashSet::new();
    while let Some(row) = rows.next()? {
        let meeting: i64 = row.get(0)?;
        let text: String = row.get(1)?;
        let quote: String = row.get::<_, Option<String>>(2)?.unwrap_or_default();
        if !valid_suggestion(&text, &quote) {
            continue;
        }
        let spelling = words(&text).join(" ");
        let review = reviews.get(&spelling);
        if review.is_none() && known.contains(&spelling) {
            continue;
        }
        if !sources.insert((spelling.clone(), meeting)) {
            continue;
        }
        let index = *indexes.entry(spelling.clone()).or_insert_with(|| {
            let index = results.len();
            results.push(json!({
                "id": spelling, "text": text,
                "status": review.map_or("proposed", |entry| entry.0.as_str()),
                "term_id": review.and_then(|entry| entry.1),
                "reviewed_at": review.map(|entry| &entry.2),
                "sources": [],
            }));
            index
        });
        if let Some(items) = results[index]["sources"].as_array_mut() {
            items.push(json!({"meeting_id": meeting, "quote": quote}));
        }
    }
    Ok(results)
}

pub(crate) fn review_proposal(
    tx: &Transaction<'_>,
    request: &Value,
    industry: &str,
) -> Result<Value> {
    let spelling = field(&request["proposal_id"], 120, true)?;
    let vocabulary = active_terms(tx, industry)?;
    if !proposals(tx, &vocabulary)?
        .iter()
        .any(|entry| entry["id"] == spelling && entry["status"] == "proposed")
    {
        bail!("Предложение уже обработано или недоступно");
    }
    let status = request["status"].as_str().unwrap_or_default();
    let term_id = match status {
        "approved" | "merged" => save(tx, request)?["id"].as_i64(),
        "rejected" => None,
        _ => bail!("Выберите действие для предложенного термина"),
    };
    tx.execute(
        "INSERT INTO term_reviews(spelling,status,term_id) VALUES (?1,?2,?3)",
        params![spelling, status, term_id],
    )?;
    Ok(json!({"id": spelling, "status": status, "term_id": term_id}))
}

fn variants_of(entry: &Value) -> impl Iterator<Item = &str> {
    entry["variants"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|variant| variant["text"].as_str())
}

fn spellings_of(entry: &Value) -> impl Iterator<Item = (&str, &str)> {
    entry["term"]
        .as_str()
        .into_iter()
        .map(|text| (text, ""))
        .chain(
            entry["variants"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|variant| {
                    Some((
                        variant["text"].as_str()?,
                        variant["context"].as_str().unwrap_or_default(),
                    ))
                }),
        )
}

fn spelling_keys(entry: &Value) -> impl Iterator<Item = (Vec<String>, Vec<String>)> + '_ {
    spellings_of(entry).map(|(text, context)| (words(text), words(context)))
}

struct Spelling {
    parts: Vec<String>,
    context: Vec<String>,
    index: usize,
}

pub(crate) struct Glossary<'a> {
    entries: &'a [Value],
    spellings: HashMap<String, Vec<Spelling>>,
}

impl<'a> Glossary<'a> {
    pub(crate) fn new(entries: &'a [Value]) -> Self {
        let mut spellings = HashMap::<String, Vec<Spelling>>::new();
        for (index, entry) in entries.iter().enumerate() {
            for (name, context) in spellings_of(entry) {
                let parts = words(name);
                if let Some(first) = parts.first() {
                    spellings.entry(first.clone()).or_default().push(Spelling {
                        parts,
                        context: words(context),
                        index,
                    });
                }
            }
        }
        for variants in spellings.values_mut() {
            variants.sort_by_key(|item| std::cmp::Reverse(item.parts.len()));
        }
        Self { entries, spellings }
    }

    fn spellings_at<'b>(
        &'b self,
        remaining: &'b [String],
        include_reference: bool,
    ) -> impl Iterator<Item = &'b Spelling> {
        let mut matches = remaining
            .first()
            .and_then(|first| self.spellings.get(first))
            .into_iter()
            .flatten()
            .filter(move |item| {
                remaining.starts_with(&item.parts)
                    && (include_reference || self.entries[item.index]["lookup_only"] != true)
            })
            .peekable();
        let longest = matches.peek().map(|item| item.parts.len());
        matches.take_while(move |item| Some(item.parts.len()) == longest)
    }

    fn match_at(&self, tokens: &[String], offset: usize) -> Option<(usize, usize)> {
        let mut contextual = None;
        let mut default = None;
        let mut multiple_defaults = false;
        for item in self.spellings_at(&tokens[offset..], false) {
            let count = item.parts.len();
            let end = offset + count;
            let choice = (count, item.index);
            if item.context.is_empty() {
                multiple_defaults |= default.is_some_and(|old| old != choice);
                default = Some(choice);
            } else {
                let before = &tokens[offset.saturating_sub(5)..offset];
                let after = &tokens[end..tokens.len().min(end + 5)];
                if [before, after].into_iter().any(|words| {
                    words
                        .windows(item.context.len())
                        .any(|window| window == item.context)
                }) {
                    if contextual.is_some_and(|old| old != choice) {
                        return None;
                    }
                    contextual = Some(choice);
                }
            }
        }
        contextual.or(default.filter(|_| !multiple_defaults))
    }

    pub(crate) fn expand(&self, text: &str) -> String {
        if self.entries.is_empty() {
            return text.to_owned();
        }
        let tokens = words(text);
        let mut output = Vec::new();
        let mut offset = 0;
        while offset < tokens.len() {
            if let Some((count, index)) = self.match_at(&tokens, offset) {
                output.push(self.entries[index]["term"].as_str().unwrap_or_default());
                offset += count;
            } else {
                output.push(&tokens[offset]);
                offset += 1;
            }
        }
        output.join(" ")
    }

    pub(crate) fn relevant<'b>(&self, texts: impl IntoIterator<Item = &'b str>) -> Vec<Value> {
        let mut used = HashSet::new();
        let mut output = Vec::new();
        for text in texts {
            let tokens = words(text);
            for offset in 0..tokens.len() {
                for item in self.spellings_at(&tokens[offset..], true) {
                    let index = item.index;
                    if !used.insert(index) {
                        continue;
                    }
                    let mut entry = self.entries[index].clone();
                    if let Some(entry) = entry.as_object_mut() {
                        entry.remove("id");
                        entry.remove("revision");
                        entry.remove("source_id");
                    }
                    output.push(entry);
                    if output.len() == 48 {
                        return output;
                    }
                }
            }
        }
        output
    }
}

pub(crate) fn valid_suggestion(term: &str, quote: &str) -> bool {
    let parts = words(term);
    term.chars().count() <= 120
        && (1..=6).contains(&parts.len())
        && words(quote)
            .windows(parts.len())
            .any(|window| window == parts.as_slice())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shared_variant_uses_context_and_keeps_unresolved_wording() {
        let entries = [
            json!({"term":"бетонировать","variants":[{"text":"залить","context":"плиту"}]}),
            json!({"term":"загрузить","variants":[{"text":"залить","context":"сборку"}]}),
        ];
        let glossary = Glossary::new(&entries);
        assert_eq!(
            glossary.expand("Нужно залить плиту"),
            "нужно бетонировать плиту"
        );
        assert_eq!(
            glossary.expand("Сборку нужно залить"),
            "сборку нужно загрузить"
        );
        assert_eq!(glossary.expand("Нужно залить"), "нужно залить");
        assert_eq!(
            glossary.expand("Плиту и сборку надо залить"),
            "плиту и сборку надо залить"
        );
        assert_eq!(glossary.relevant(["Нужно залить"]).len(), 2);
    }
}
