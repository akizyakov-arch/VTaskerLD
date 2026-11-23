use super::{
    field, industry_catalog, list, normalize_industry, package, spelling_keys, validated_term,
    words,
};
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, Transaction};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

const COMPANY: &str = "vtask-company-dictionary";
const INDUSTRY: &str = "vtask-industry-dictionary";

fn portable(mut term: Value) -> Value {
    if let Some(fields) = term.as_object_mut() {
        for key in ["id", "revision", "lookup_only"] {
            fields.remove(key);
        }
    }
    term
}

pub(crate) fn export(db: &Connection, scope: &str, industry: &str) -> Result<Value> {
    match scope {
        "company" => Ok(json!({
            "format":COMPANY,"schema_version":1,"entries":list(db)?.into_iter().map(portable).collect::<Vec<_>>(),
        })),
        "industry" => {
            let document = package(db, industry)?.context("У выбранной отрасли нет пакета")?;
            let entries: Vec<_> = document["entries"]
                .as_array()
                .unwrap()
                .iter()
                .cloned()
                .map(portable)
                .collect();
            Ok(
                json!({"format":INDUSTRY,"schema_version":1,"industry_id":industry,
                "industry_name_ru":document["title"],"revision":document["revision"],"entries":entries}),
            )
        }
        _ => bail!("Выберите словарь для экспорта"),
    }
}

#[derive(Default)]
struct ImportPlan {
    rows: Vec<Value>,
    accepted: Vec<Value>,
    added: usize,
    updated: usize,
    duplicate: usize,
    conflict: usize,
    invalid: usize,
}

impl ImportPlan {
    fn record(&mut self, term: &str, status: &str, detail: Option<&str>) {
        match status {
            "new" => self.added += 1,
            "updated" => self.updated += 1,
            "duplicate" => self.duplicate += 1,
            "conflict" => self.conflict += 1,
            _ => self.invalid += 1,
        }
        self.rows
            .push(json!({"id": self.rows.len()+1,"term":term,"status":status,"detail":detail}));
    }

    fn report(&self, scope: &str, title: &str) -> Value {
        json!({"scope":scope,"title":title,"added":self.added,"updated":self.updated,
            "duplicate":self.duplicate,"conflict":self.conflict,"invalid":self.invalid,"rows":self.rows})
    }
}

fn title_hint(entry: &Value) -> &str {
    entry["term"]
        .as_str()
        .or_else(|| entry["canonical"].as_str())
        .unwrap_or("Без названия")
}

fn plan_company(entries: &[Value], existing: &[Value]) -> ImportPlan {
    let mut plan = ImportPlan::default();
    let mut terms: Vec<_> = existing.iter().cloned().map(portable).collect();
    let mut occupied = terms
        .iter()
        .enumerate()
        .flat_map(|(index, term)| spelling_keys(term).map(move |key| (key, index)))
        .collect::<HashMap<_, _>>();
    for raw in entries {
        let entry = match validated_term(raw) {
            Ok(term) => term,
            Err(err) => {
                plan.record(title_hint(raw), "invalid", Some(&err.to_string()));
                continue;
            }
        };
        let title = entry["term"].as_str().unwrap();
        if let Some(&index) = spelling_keys(&entry).find_map(|key| occupied.get(&key)) {
            if entry == terms[index] {
                plan.record(title, "duplicate", None);
            } else {
                let detail = format!("Совпадает с записью «{}»", title_hint(&terms[index]));
                plan.record(title, "conflict", Some(&detail));
            }
            continue;
        }
        plan.record(title, "new", None);
        occupied.extend(spelling_keys(&entry).map(|key| (key, terms.len())));
        terms.push(entry.clone());
        plan.accepted.push(entry);
    }
    plan
}

fn archive_term(raw: &Value) -> Result<Value> {
    fn cyrillic(text: &str) -> bool {
        text.chars().any(|c| matches!(c, 'А'..='я' | 'Ё' | 'ё'))
    }
    fn keep(text: &str) -> bool {
        cyrillic(text)
            || matches!(
                text,
                "GraphQL" | "Kubernetes" | "Docker" | "DevOps" | "HoReCa" | "RevPAR"
            )
            || text
                .as_bytes()
                .first()
                .is_some_and(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
                && text
                    .bytes()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || b"/&+:-".contains(&c))
            || text == "360°"
    }
    let mut canonical = field(&raw["canonical"], 120, true)?.to_owned();
    let definition = field(&raw["definition_ru"], 600, true)?;
    let aliases = raw["aliases"].as_array().context("Нет списка вариантов")?;
    let aliases = aliases
        .iter()
        .map(|value| field(value, 120, true))
        .collect::<Result<Vec<_>>>()?;
    if !keep(&canonical) {
        canonical = aliases.iter().find(|alias| cyrillic(alias)).map_or_else(
            || definition.to_owned(),
            |alias| {
                let mut letters = alias.chars();
                letters
                    .next()
                    .unwrap()
                    .to_uppercase()
                    .chain(letters)
                    .collect()
            },
        );
    }
    let mut seen = HashSet::from([words(&canonical)]);
    let variants: Vec<_> = aliases
        .into_iter()
        .filter(|alias| keep(alias) && seen.insert(words(alias)))
        .map(|alias| json!({"text":alias,"language":if cyrillic(alias) {"ru"} else {""}}))
        .collect();
    Ok(
        json!({"term":canonical,"definition":definition,"language":raw["language"],"variants":variants}),
    )
}

fn package_entry(raw: &Value, industry: &str, archive: bool) -> Result<Value> {
    let source = field(&raw[if archive { "id" } else { "source_id" }], 100, true)?;
    if !source
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
    {
        bail!("Некорректный идентификатор записи пакета");
    }
    if archive && raw["status"] != "active" {
        bail!("Запись пакета не активна");
    }
    let data = if archive {
        archive_term(raw)?
    } else {
        raw.clone()
    };
    let mut entry = validated_term(&data)?;
    let hash = Sha256::digest(format!("{industry}:{source}").as_bytes());
    let number = hash[..6]
        .iter()
        .fold(0_i64, |value, &byte| value * 256 + i64::from(byte));
    entry["id"] = json!(-1_000_000 - number);
    entry["revision"] = json!(0);
    entry["source_id"] = json!(source);
    entry["lookup_only"] = json!(true);
    if let Some(category) = raw["category"]
        .as_str()
        .filter(|kind| matches!(*kind, "term" | "slang" | "abbreviation"))
    {
        entry["category"] = json!(category);
    }
    if let Some(specializations) = raw.get("specialization_ids") {
        let ids = specializations
            .as_array()
            .filter(|values| values.len() <= 30)
            .context("Некорректный список специализаций")?;
        let mut tags = Vec::new();
        for id in ids {
            let id = id
                .as_str()
                .filter(|id| super::valid_specialization_id(id))
                .context("Некорректный идентификатор специализации")?;
            if !tags.contains(&id) {
                tags.push(id);
            }
        }
        if !tags.is_empty() {
            entry["specialization_ids"] = json!(tags);
        }
    }
    Ok(entry)
}

fn plan_industry(
    entries: &[Value],
    industry: &str,
    archive_id: Option<&str>,
    merged: &mut Vec<Value>,
) -> ImportPlan {
    let mut plan = ImportPlan::default();
    let mut seen = HashSet::new();
    let mut indexes: HashMap<String, usize> = merged
        .iter()
        .enumerate()
        .map(|(index, entry)| (entry["source_id"].as_str().unwrap().to_owned(), index))
        .collect();
    for raw in entries {
        let proposed = if archive_id.is_some_and(|id| raw["industry_id"] != id) {
            Err(anyhow::anyhow!("Запись относится к другой отрасли"))
        } else {
            package_entry(raw, industry, archive_id.is_some())
        };
        let mut term = match proposed {
            Ok(term) => term,
            Err(err) => {
                plan.record(title_hint(raw), "invalid", Some(&err.to_string()));
                continue;
            }
        };
        let title = term["term"].as_str().unwrap().to_owned();
        let source = term["source_id"].as_str().unwrap().to_owned();
        if !seen.insert(source.clone()) {
            plan.record(
                &title,
                "conflict",
                Some("Идентификатор повторяется в файле"),
            );
            continue;
        }
        if let Some(&index) = indexes.get(&source) {
            term["id"] = merged[index]["id"].clone();
            if term == merged[index] {
                plan.record(&title, "duplicate", None);
            } else {
                merged[index] = term;
                plan.record(&title, "updated", None);
            }
        } else {
            indexes.insert(source, merged.len());
            merged.push(term);
            plan.record(&title, "new", None);
        }
    }
    plan
}

pub(crate) fn import(tx: &Transaction<'_>, request: &Value, apply: bool) -> Result<Value> {
    let document = &request["document"];
    let entries = document["entries"]
        .as_array()
        .filter(|items| items.len() <= 3000)
        .context("Выберите JSON одного пакета или словаря компании с числом записей до 3000")?;
    let archive = document["format"].is_null() && document["schema_version"] == "1.0";
    let (plan, current, storage, scope, title) =
        if document["format"] == COMPANY && document["schema_version"] == 1 {
            let current = json!(list(tx)?);
            let plan = plan_company(entries, current.as_array().unwrap());
            (
                plan,
                current,
                None,
                "company",
                "Словарь компании".to_owned(),
            )
        } else if archive || (document["format"] == INDUSTRY && document["schema_version"] == 1) {
            let raw_id = field(&document["industry_id"], 48, true)?;
            let id = raw_id;
            let id = if archive {
                id.split_once('_')
                    .filter(|(prefix, _)| prefix.bytes().all(|byte| byte.is_ascii_digit()))
                    .map_or(id, |(_, name)| name)
            } else {
                id
            };
            let id = normalize_industry(if id == "general" { "universal" } else { id });
            if id.is_empty()
                || !id
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
            {
                bail!("Некорректный идентификатор отрасли");
            }
            let title = field(&document["industry_name_ru"], 120, true)?;
            let revision = field(&document["revision"], 60, true)?;
            let current = package(tx, id)?.unwrap_or(Value::Null);
            let title = industry_catalog(tx)?
                .iter()
                .find(|option| option["id"] == id)
                .and_then(|option| option["title"].as_str())
                .unwrap_or(title)
                .to_owned();
            let mut merged = current["entries"].as_array().cloned().unwrap_or_default();
            let plan = plan_industry(entries, id, archive.then_some(raw_id), &mut merged);
            let updated = json!({"title":title,"revision":revision,"entries":merged});
            (
                plan,
                current,
                Some((format!("industry_package:{id}"), updated)),
                "industry",
                title,
            )
        } else {
            bail!("Неподдерживаемый формат или версия словаря");
        };
    let mut result = plan.report(scope, &title);
    let token = format!(
        "{:x}",
        Sha256::digest(json!([document, current]).to_string())
    );
    if apply {
        if request["token"] != token {
            bail!("Словарь изменился после проверки. Проверьте файл ещё раз");
        }
        if plan.added + plan.updated == 0 {
            bail!("Нет записей для импорта");
        }
        if let Some((key, data)) = storage {
            tx.execute(
                "INSERT INTO workspace_settings(key,data_json) VALUES (?1,?2)
                ON CONFLICT(key) DO UPDATE SET data_json=excluded.data_json",
                params![key, data.to_string()],
            )?;
        } else {
            let mut insert = tx.prepare("INSERT INTO company_terms(data_json) VALUES (?1)")?;
            for entry in plan.accepted {
                insert.execute([entry.to_string()])?;
            }
        }
    }
    result["token"] = json!(token);
    Ok(result)
}
