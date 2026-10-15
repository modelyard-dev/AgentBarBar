use crate::Result;
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub const TOKEN_LIMIT: i64 = 9_007_199_254_740_991;
pub const METRICS: [&str; 7] = [
    "input",
    "output",
    "cacheRead",
    "cacheWrite",
    "cachedOutput",
    "reasoning",
    "total",
];
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MetricState {
    Known,
    Unknown,
    Unsupported,
    #[default]
    NotAvailable,
    Partial,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Metric {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<i64>,
    pub state: MetricState,
}
impl Metric {
    pub fn new(value: Option<i64>) -> Self {
        Self {
            value,
            state: if value.is_some() {
                MetricState::Known
            } else {
                MetricState::NotAvailable
            },
        }
    }
    pub fn absent(state: MetricState) -> Self {
        Self { value: None, state }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProjectIdentity {
    pub id: String,
    pub name: String,
    pub path: String,
    pub detection_method: String,
    pub confidence: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedUsageRecord {
    pub id: String,
    pub timestamp: String,
    #[serde(rename = "agentID")]
    pub agent_id: String,
    pub agent_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_model_name: Option<String>,
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<ProjectIdentity>,
    pub metrics: BTreeMap<String, Metric>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub currency: Option<String>,
    pub cost_state: MetricState,
    pub source_type: String,
    pub source_path: String,
    #[serde(rename = "sourceEventID")]
    pub source_event_id: String,
    pub source_line: u64,
    pub source_offset: u64,
    #[serde(rename = "collectorID")]
    pub collector_id: String,
    pub collector_version: String,
    pub parser_version: String,
    pub is_estimated: bool,
    pub confidence: f64,
    pub quality: String,
    pub fingerprint: String,
    pub source_metadata: BTreeMap<String, String>,
    pub created_at: String,
}
impl NormalizedUsageRecord {
    pub fn validate(&self) -> Result<()> {
        timestamp(&self.timestamp)?;
        if self.id != hash(&self.source_event_id)
            || self.fingerprint != self.id
            || !self
                .source_event_id
                .starts_with(&(self.agent_id.clone() + ":"))
        {
            return Err("Invalid logical identity".into());
        }
        if self.metrics.len() != 7 {
            return Err("Incomplete metric contract".into());
        }
        for name in METRICS {
            let m = self.metrics.get(name).ok_or("Missing metric")?;
            if let Some(n) = m.value {
                // Swift limits raw counters, but permits larger derived sums in Int64.
                if n < 0 || !matches!(m.state, MetricState::Known | MetricState::Partial) {
                    return Err("Invalid metric state/value".into());
                }
            } else if m.state == MetricState::Known {
                return Err("Known metric requires a value".into());
            }
        }
        if self.cost.is_some_and(|c| !c.is_finite() || c < 0.) {
            return Err("Invalid cost".into());
        }
        Ok(())
    }
    pub fn golden(&self) -> serde_json::Value {
        let mut v = serde_json::to_value(self).expect("validated serializable metadata");
        let fields = [
            "id",
            "timestamp",
            "agentID",
            "provider",
            "rawModelName",
            "sessionID",
            "metrics",
            "sourceEventID",
            "fingerprint",
            "parserVersion",
            "quality",
            "sourceMetadata",
        ];
        v.as_object_mut()
            .unwrap()
            .retain(|k, _| fields.contains(&k.as_str()));
        v
    }
}
pub fn hash(s: &str) -> String {
    format!("{:x}", Sha256::digest(s.as_bytes()))
}
pub fn timestamp(s: &str) -> Result<DateTime<Utc>> {
    Ok(DateTime::parse_from_rfc3339(s)?.with_timezone(&Utc))
}
pub fn iso(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Millis, true)
}
pub fn empty_metrics() -> BTreeMap<String, Metric> {
    METRICS
        .into_iter()
        .map(|k| {
            (
                k.into(),
                Metric::absent(if k == "cachedOutput" {
                    MetricState::Unsupported
                } else {
                    MetricState::NotAvailable
                }),
            )
        })
        .collect()
}
pub fn checked_sum(parts: &[Option<i64>]) -> Result<Option<i64>> {
    let mut n = 0i64;
    for p in parts {
        let Some(p) = p else { return Ok(None) };
        n = n.checked_add(*p).ok_or("Token overflow")?;
    }
    Ok(Some(n))
}
