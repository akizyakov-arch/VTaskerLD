//! Company-wide terms shared by the desktop client and the meeting analysis pipeline.
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

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

pub(crate) fn industry_terms(industry: &str) -> Vec<Value> {
    static VOCABULARY: std::sync::LazyLock<Value> = std::sync::LazyLock::new(|| {
        serde_json::from_str(include_str!("industry-glossaries.json"))
            .expect("Built-in industry vocabulary must be valid JSON")
    });
    [
        VOCABULARY["common"].as_array(),
        VOCABULARY[industry].as_array(),
    ]
    .into_iter()
    .flatten()
    .flatten()
    .enumerate()
    .map(|(index, entry)| {
        let mut entry = entry.clone();
        entry["id"] = json!(-(index as i64) - 1);
        entry["revision"] = json!(0);
        entry
    })
    .collect()
}

pub(crate) fn effective_terms(company: &[Value], industry: &[Value]) -> Vec<Value> {
    let mut merged = company.to_vec();
    let mut claimed = company
        .iter()
        .flat_map(|entry| entry["term"].as_str().into_iter().chain(variants_of(entry)))
        .map(words)
        .collect::<HashSet<_>>();

    for starter in industry {
        let spelling = words(starter["term"].as_str().unwrap_or_default());
        let same_term = merged
            .iter_mut()
            .find(|entry| words(entry["term"].as_str().unwrap_or_default()) == spelling);
        if same_term.is_none() && !claimed.insert(spelling) {
            continue;
        }
        let variants: Vec<Value> = starter["variants"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|variant| claimed.insert(words(variant["text"].as_str().unwrap_or_default())))
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
    Ok(effective_terms(&list(db)?, &industry_terms(industry)))
}

pub(crate) fn save(db: &Connection, request: &Value) -> Result<Value> {
    let data = &request["data"];
    let term = field(&data["term"], 120, true)?;
    let term_language = language(&data["language"])?;
    let section = field(&data["section"], 80, false)?;
    let variants = data["variants"]
        .as_array()
        .filter(|items| !items.is_empty() && items.len() <= 30)
        .context("Добавьте от одного до тридцати вариантов термина")?;
    let mut spellings = HashSet::from([words(term)]);
    let mut cleaned = Vec::with_capacity(variants.len());
    for variant in variants {
        let text = field(&variant["text"], 120, true)?;
        if !spellings.insert(words(text)) {
            bail!("«{text}» уже указан в этой записи");
        }
        cleaned.push(json!({"text":text,"language":language(&variant["language"])?}));
    }
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
    for entry in list(db)?.iter().filter(|entry| entry["id"].as_i64() != id) {
        let existing = entry["term"].as_str().unwrap_or_default();
        if std::iter::once(existing)
            .chain(variants_of(entry))
            .any(|text| spellings.contains(&words(text)))
        {
            bail!("Такое написание уже есть в записи «{existing}». Откройте её в справочнике");
        }
    }
    let raw = json!({"term":term,"language":term_language,"section":section,"variants":cleaned})
        .to_string();
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

fn variants_of(entry: &Value) -> impl Iterator<Item = &str> {
    entry["variants"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|variant| variant["text"].as_str())
}

pub(crate) struct Glossary<'a> {
    entries: &'a [Value],
    // Sorted by length so compound expressions have priority over single words.
    spellings: HashMap<String, Vec<(Vec<String>, usize)>>,
}

impl<'a> Glossary<'a> {
    pub(crate) fn new(entries: &'a [Value]) -> Self {
        let mut spellings = HashMap::<String, Vec<(Vec<String>, usize)>>::new();
        for (index, entry) in entries.iter().enumerate() {
            for name in entry["term"].as_str().into_iter().chain(variants_of(entry)) {
                let parts = words(name);
                if let Some(first) = parts.first() {
                    spellings
                        .entry(first.clone())
                        .or_default()
                        .push((parts, index));
                }
            }
        }
        for variants in spellings.values_mut() {
            variants.sort_by_key(|(parts, _)| std::cmp::Reverse(parts.len()));
        }
        Self { entries, spellings }
    }

    fn match_at(&self, remaining: &[String]) -> Option<(usize, usize)> {
        let matches = self.spellings.get(remaining.first()?)?;
        matches
            .iter()
            .find(|(words, _)| remaining.starts_with(words))
            .map(|(words, index)| (words.len(), *index))
    }

    pub(crate) fn expand(&self, text: &str) -> String {
        if self.entries.is_empty() {
            return text.to_owned();
        }
        let tokens = words(text);
        let mut output = Vec::new();
        let mut offset = 0;
        while offset < tokens.len() {
            if let Some((count, index)) = self.match_at(&tokens[offset..]) {
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
                if let Some((_, index)) = self.match_at(&tokens[offset..]) {
                    if !used.insert(index) {
                        continue;
                    }
                    let mut entry = self.entries[index].clone();
                    if let Some(entry) = entry.as_object_mut() {
                        entry.remove("id");
                        entry.remove("revision");
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
