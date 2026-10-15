use crate::{domain::*, Result};
use chrono::{DateTime, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryFilter {
    pub start: Option<f64>,
    pub end: Option<f64>,
    pub agent: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
    pub provider: Option<String>,
    pub session: Option<String>,
}
impl QueryFilter {
    pub fn matches(&self, e: &NormalizedUsageRecord) -> Result<bool> {
        let t = timestamp(&e.timestamp)?.timestamp_millis() as f64 / 1000.;
        if self.start.is_some_and(|n| t < n) || self.end.is_some_and(|n| t >= n) {
            return Ok(false);
        }
        for (f, v) in [
            (&self.agent, Some(e.agent_id.as_str())),
            (&self.model, e.raw_model_name.as_deref()),
            (&self.project, e.project.as_ref().map(|x| x.id.as_str())),
            (&self.provider, e.provider.as_deref()),
            (&self.session, e.session_id.as_deref()),
        ] {
            if let Some(f) = f {
                if !(v == Some(f.as_str()) || (f == "unknown" && v.is_none())) {
                    return Ok(false);
                }
            }
        }
        Ok(true)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MetricAggregate {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<i64>,
    pub state: MetricState,
    pub known_events: usize,
    pub total_events: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    pub metrics: BTreeMap<String, MetricAggregate>,
    pub events: usize,
    pub sessions: usize,
    pub agents: usize,
    pub projects: usize,
    pub active_agents: usize,
    pub estimated_events: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    pub cost_known_events: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub currency: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uncached_input: Option<MetricAggregate>,
}
pub fn summarize(
    events: &[NormalizedUsageRecord],
    filter: &QueryFilter,
    now: DateTime<Utc>,
) -> Result<UsageSummary> {
    let rows = events
        .iter()
        .filter_map(|e| match filter.matches(e) {
            Ok(true) => Some(Ok(e)),
            Ok(false) => None,
            Err(e) => Some(Err(e)),
        })
        .collect::<Result<Vec<_>>>()?;
    let n = rows.len();
    let mut metrics = BTreeMap::new();
    for k in METRICS {
        let mut sum = 0i64;
        let (mut known, mut unsupported, mut unknown, mut partial) = (0, 0, 0, false);
        for e in &rows {
            let m = e.metrics.get(k).ok_or("Missing metric")?;
            if let Some(v) = m.value {
                sum = sum.checked_add(v).ok_or("Aggregate Int64 overflow")?;
                known += 1;
            }
            partial |= m.state == MetricState::Partial;
            unsupported += usize::from(m.state == MetricState::Unsupported);
            unknown += usize::from(m.state == MetricState::Unknown);
        }
        let state = if known > 0 {
            if known < n || partial {
                MetricState::Partial
            } else {
                MetricState::Known
            }
        } else if n > 0 && unsupported == n {
            MetricState::Unsupported
        } else if n > 0 && unknown == n {
            MetricState::Unknown
        } else {
            MetricState::NotAvailable
        };
        metrics.insert(
            k.into(),
            MetricAggregate {
                value: if known > 0 { Some(sum) } else { None },
                state,
                known_events: known,
                total_events: n,
            },
        );
    }
    let mut agents = BTreeSet::new();
    let mut sessions = BTreeSet::new();
    let mut projects = BTreeSet::new();
    let mut active = BTreeSet::new();
    let mut costs = Vec::new();
    let mut raw = Vec::new();
    for e in &rows {
        agents.insert(&e.agent_id);
        if let Some(s) = &e.session_id {
            sessions.insert(format!("{}:{s}", e.agent_id));
        }
        if let Some(p) = &e.project {
            projects.insert(&p.id);
        }
        if timestamp(&e.timestamp)? >= now - Duration::minutes(15) {
            active.insert(&e.agent_id);
        }
        if let Some(c) = e.cost {
            costs.push((c, e.currency.clone()));
        }
        if e.agent_id == "deepseek-harness"
            && e.source_event_id.starts_with("deepseek-harness:ledger:")
        {
            if let (Some(i), Some(r), Some(w)) = (
                e.metrics["input"].value,
                e.metrics["cacheRead"].value,
                e.metrics["cacheWrite"].value,
            ) {
                raw.push(i - r - w);
            }
        }
    }
    let currencies = costs.iter().map(|x| x.1.clone()).collect::<BTreeSet<_>>();
    let priced = !costs.is_empty() && currencies.len() == 1 && !currencies.contains(&None);
    Ok(UsageSummary {
        metrics,
        events: n,
        sessions: sessions.len(),
        agents: agents.len(),
        projects: projects.len(),
        active_agents: active.len(),
        estimated_events: rows.iter().filter(|x| x.is_estimated).count(),
        cost: if priced {
            Some(costs.iter().map(|x| x.0).sum())
        } else {
            None
        },
        cost_known_events: if priced { costs.len() } else { 0 },
        // Swift takes max(currency) over all selected rows, even unpriced ones.
        currency: if costs.is_empty() || priced {
            rows.iter().filter_map(|e| e.currency.clone()).max()
        } else {
            None
        },
        uncached_input: if raw.is_empty() {
            None
        } else {
            Some(MetricAggregate {
                value: Some(raw.iter().try_fold(0i64, |s, n| {
                    s.checked_add(*n).ok_or("Uncached aggregate overflow")
                })?),
                state: if raw.len() == n {
                    MetricState::Known
                } else {
                    MetricState::Partial
                },
                known_events: raw.len(),
                total_events: n,
            })
        },
    })
}
pub fn zone(name: &str) -> Result<Tz> {
    let mapped = match name {
        "China Standard Time" => "Asia/Shanghai",
        "UTC" => "UTC",
        "Pacific Standard Time" => "America/Los_Angeles",
        "W. Europe Standard Time" => "Europe/Berlin",
        _ => name,
    };
    Ok(mapped.parse()?)
}
fn midnight(date: NaiveDate, z: Tz) -> Result<DateTime<Utc>> {
    let local = date.and_hms_opt(0, 0, 0).ok_or("Invalid date")?;
    resolve_local(local, z)
}
fn resolve_local(local: NaiveDateTime, z: Tz) -> Result<DateTime<Utc>> {
    if let Some(t) = z.from_local_datetime(&local).earliest() {
        return Ok(t.with_timezone(&Utc));
    }
    // Calendar.startOfDay selects the first legal instant on a midnight DST gap.
    // Bound this search to one local date; entirely skipped civil dates remain explicit gaps.
    for seconds in 1..86_400 {
        if let Some(t) = z
            .from_local_datetime(&(local + Duration::seconds(seconds)))
            .earliest()
        {
            return Ok(t.with_timezone(&Utc));
        }
    }
    Err("Civil date entirely skipped; explicit calendar policy required".into())
}
pub fn range_filter(range: &str, now: DateTime<Utc>, timezone: &str) -> Result<QueryFilter> {
    if range == "all" {
        return Ok(QueryFilter::default());
    }
    let z = zone(timezone)?;
    let today = now.with_timezone(&z).date_naive();
    let origin = midnight(today, z)?;
    // Swift Calendar.date(byAdding:.day,to:startOfDay) retains the origin wall time.
    // In a midnight DST gap that time is 01:00, including on subsequent days.
    let wall_time = origin.with_timezone(&z).time();
    let days = match range {
        "today" => 0,
        "7" => 6,
        "30" => 29,
        "yesterday" => 1,
        _ => return Err("Unknown range".into()),
    };
    let begin = today
        .checked_sub_signed(Duration::days(days))
        .ok_or("Date underflow")?;
    let end = if range == "yesterday" {
        today
    } else {
        today.succ_opt().ok_or("Date overflow")?
    };
    Ok(QueryFilter {
        start: Some(resolve_local(begin.and_time(wall_time), z)?.timestamp() as f64),
        end: Some(resolve_local(end.and_time(wall_time), z)?.timestamp() as f64),
        ..Default::default()
    })
}
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GroupRow {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity: Option<String>,
    pub models: Vec<String>,
    #[serde(rename = "agentIDs")]
    pub agent_ids: Vec<String>,
    #[serde(rename = "projectIDs")]
    pub project_ids: Vec<String>,
    pub summary: UsageSummary,
}
pub fn groups(
    events: &[NormalizedUsageRecord],
    dimension: &str,
    filter: &QueryFilter,
    now: DateTime<Utc>,
) -> Result<Vec<GroupRow>> {
    let mut buckets: BTreeMap<String, Vec<NormalizedUsageRecord>> = BTreeMap::new();
    for e in events {
        if filter.matches(e)? {
            let id = match dimension {
                "agents" => Some(e.agent_id.clone()),
                "models" => e.raw_model_name.clone(),
                "sessions" => e.session_id.clone(),
                "projects" => e.project.as_ref().map(|p| p.id.clone()),
                _ => return Err("Unknown dimension".into()),
            }
            .unwrap_or("unknown".into());
            buckets.entry(id).or_default().push(e.clone());
        }
    }
    let mut out = Vec::new();
    for (id, rows) in buckets {
        let name = if dimension == "agents" {
            rows[0].agent_name.clone()
        } else if dimension == "projects" {
            rows[0]
                .project
                .as_ref()
                .map(|x| x.name.clone())
                .unwrap_or("Unknown project".into())
        } else {
            id.clone()
        };
        out.push(GroupRow {
            id,
            name,
            path: if dimension == "projects" {
                rows[0].project.as_ref().map(|x| x.path.clone())
            } else {
                None
            },
            last_activity: rows.iter().map(|e| e.timestamp.clone()).max(),
            models: rows
                .iter()
                .filter_map(|e| e.raw_model_name.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect(),
            agent_ids: rows
                .iter()
                .map(|e| e.agent_id.clone())
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect(),
            project_ids: rows
                .iter()
                .filter_map(|e| e.project.as_ref().map(|p| p.id.clone()))
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect(),
            summary: summarize(&rows, &QueryFilter::default(), now)?,
        });
    }
    // Swift SQL GROUP BY key yields lexical ties in the current fixture. Not a claimed universal Swift tie guarantee.
    out.sort_by(|a, b| {
        b.summary.metrics["total"]
            .value
            .cmp(&a.summary.metrics["total"].value)
            .then_with(|| a.id.cmp(&b.id))
    });
    Ok(out)
}
