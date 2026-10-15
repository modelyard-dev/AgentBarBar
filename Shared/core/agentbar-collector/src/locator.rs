use crate::io::{self, FileSnapshot};
use agentbar_core::{
    domain::hash,
    parser::{adapter, ParseContext, ParserState, UsageAdapter},
    Result,
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    Confirmed,
    Probable,
    Unsupported,
    Unavailable,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDescriptor {
    pub agent: String,
    pub source_id: String,
    pub source_kind: String,
    pub path: PathBuf,
    pub root: PathBuf,
    pub format: String,
    pub parser_version: String,
    pub source_schema_version: String,
    pub confidence: Confidence,
    pub read_mode: String,
    pub snapshot: FileSnapshot,
    pub schema_keys: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Discovery {
    pub agent: String,
    pub status: Confidence,
    pub roots: Vec<PathBuf>,
    pub installation_evidence: Vec<String>,
    pub sources: Vec<SourceDescriptor>,
    pub limited: bool,
    pub errors: Vec<String>,
    pub probe_bytes: u64,
}
#[derive(Clone)]
pub struct Profile {
    pub home: PathBuf,
    pub appdata: Option<PathBuf>,
    pub localappdata: Option<PathBuf>,
    pub codex_home: Option<PathBuf>,
    pub claude_config: Option<PathBuf>,
}
impl Profile {
    pub fn current() -> Result<Self> {
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .ok_or("USER_PROFILE_UNAVAILABLE")?;
        Ok(Self {
            home: home.into(),
            appdata: std::env::var_os("APPDATA").map(Into::into),
            localappdata: std::env::var_os("LOCALAPPDATA").map(Into::into),
            codex_home: std::env::var_os("CODEX_HOME").map(Into::into),
            claude_config: std::env::var_os("CLAUDE_CONFIG_DIR").map(Into::into),
        })
    }
    pub fn roots(&self, agent: &str) -> Result<Vec<PathBuf>> {
        match agent {
            "codex" => {
                let p = self.codex_home.clone().unwrap_or(self.home.join(".codex"));
                Ok(vec![p.join("sessions"), p.join("archived_sessions")])
            }
            "claude-code" => Ok(vec![self
                .claude_config
                .clone()
                .unwrap_or(self.home.join(".claude"))
                .join("projects")]),
            "claude-desktop" => {
                let mut roots = Vec::new();
                if let Some(p) = &self.appdata {
                    roots.push(p.join("Claude"));
                    roots.push(p.join("Claude/local-agent-mode-sessions"));
                }
                if let Some(p) = &self.localappdata {
                    roots.push(p.join("Claude"));
                    roots.push(p.join("Claude/IndexedDB"));
                    roots.push(p.join("Claude/local-agent-mode-sessions"));
                    roots.push(p.join("AnthropicClaude"));
                    roots.push(p.join("AnthropicClaude/local-agent-mode-sessions"));
                }
                Ok(roots)
            }
            "kimi-cli" => Ok(vec![self.home.join(".kimi/sessions")]),
            "pi" => Ok(vec![self.home.join(".pi/agent/sessions")]),
            "workbuddy" => Ok(vec![self.home.join(".workbuddy/projects")]),
            "deepseek-harness" => Ok(vec![self.home.join(".dsh/storages")]),
            "gemini" => Ok(vec![self.home.join(".gemini/tmp")]),
            "qwen" => Ok(vec![self.home.join(".qwen/usage")]),
            "cline" => Ok(self.appdata.as_ref().map(|p| vec![p.join("Code/User/globalStorage/saoudrizwan.claude-dev/tasks")]).unwrap_or_default()),
            "opencode" => {
                let mut roots = vec![self.home.join(".local/share/opencode")];
                if let Some(p) = &self.localappdata {
                    roots.push(p.join("opencode"));
                }
                if let Some(p) = &self.appdata {
                    roots.push(p.join("opencode"));
                }
                Ok(roots)
            }
            "antigravity" => Ok(vec![self
                .home
                .join(".gemini/antigravity-cli/conversations")]),
            "antigravity-ide" => Ok(vec![self.home.join(".gemini/antigravity/conversations")]),
            _ => Err("UNKNOWN_AGENT_LOCATOR".into()),
        }
    }
    pub fn installation(&self, agent: &str) -> Vec<String> {
        let mut candidates = Vec::new();
        let binary = match agent {
            "claude-code" => "claude",
            "kimi-cli" => "kimi",
            "deepseek-harness" => "dsh",
            "gemini" => "gemini",
            _ => agent,
        };
        for directory in std::env::var_os("PATH")
            .map(|v| std::env::split_paths(&v).collect::<Vec<_>>())
            .unwrap_or_default()
        {
            for ext in ["exe", "cmd", "ps1"] {
                let p = directory.join(format!("{binary}.{ext}"));
                if p.is_file() {
                    candidates.push(format!("executable:{}", p.display()));
                }
            }
        }
        if let Some(roaming) = &self.appdata {
            let p = roaming.join("npm").join(format!("{binary}.cmd"));
            if p.is_file() {
                candidates.push(format!("executable:{}", p.display()));
            }
            if agent == "kimi-cli" {
                let p = roaming.join("uv/tools/kimi-cli/Scripts/kimi.exe");
                if p.is_file() {
                    candidates.push(format!("executable:{}", p.display()));
                }
            }
        }
        let p = self.home.join(".local/bin").join(format!("{binary}.exe"));
        if p.is_file() {
            candidates.push(format!("executable:{}", p.display()));
        }
        if agent == "claude-desktop" {
            for base in [&self.localappdata, &self.appdata].into_iter().flatten() {
                for relative in ["Programs/Claude/Claude.exe", "Claude/Claude.exe", "AnthropicClaude/Claude.exe"] {
                    let p = base.join(relative);
                    if p.is_file() {
                        candidates.push(format!("application:{}", p.display()));
                    }
                }
            }
        }
        candidates.sort();
        candidates.dedup();
        candidates
    }
}
pub trait SourceLocator {
    fn discover(&self, agent: &str, roots: &[PathBuf], cancel: &AtomicBool) -> Result<Discovery>;
}
pub struct NativeLocator {
    pub profile: Profile,
    pub max_entries: usize,
    pub max_sources: usize,
    pub timeout: Duration,
    pub probe: bool,
}
impl NativeLocator {
    pub fn new(profile: Profile) -> Self {
        Self {
            profile,
            max_entries: 50_000,
            max_sources: 8192,
            timeout: Duration::from_secs(10),
            probe: true,
        }
    }
}
pub fn matches(agent: &str, path: &Path) -> bool {
    let name = path.file_name().and_then(|p| p.to_str()).unwrap_or("");
    match agent {
        "codex" => name.starts_with("rollout-") && name.ends_with(".jsonl"),
        "claude-code" => name.ends_with(".jsonl"),
        "kimi-cli" => name == "wire.jsonl",
        "pi" | "workbuddy" => name.ends_with(".jsonl"),
        "deepseek-harness" => name == "dsh_token_usage_sidebar.sqlite",
        "gemini" => name.starts_with("session-") && (name.ends_with(".jsonl") || (name.ends_with(".json") && !path.with_extension("jsonl").exists())),
        "qwen" => {let stem=name.strip_prefix("token-usage-").and_then(|s|s.strip_suffix(".jsonl"));stem.is_some_and(|s|s.len()==7 && s.bytes().enumerate().all(|(i,b)|if i==4 {b==b'-'}else{b.is_ascii_digit()}))},
        "cline" => name == "ui_messages.json",
        "opencode" => name == "opencode.db",
        "antigravity" | "antigravity-ide" => name.ends_with(".db"),
        _ => false,
    }
}
pub fn safe_root(root: &Path, profile: &Profile) -> Result<()> {
    io::safe_path(root)?;
    if root.parent().is_none()
        || root == profile.home
        || root.components().count() < 3
        || profile.appdata.as_ref() == Some(&root.to_path_buf())
        || profile.localappdata.as_ref() == Some(&root.to_path_buf())
    {
        return Err("ROOT_TOO_BROAD".into());
    }
    Ok(())
}
impl SourceLocator for NativeLocator {
    fn discover(
        &self,
        agent: &str,
        overrides: &[PathBuf],
        cancel: &AtomicBool,
    ) -> Result<Discovery> {
        let parser = adapter(agent)?;
        let roots = if overrides.is_empty() {
            self.profile.roots(agent)?
        } else {
            overrides.to_vec()
        };
        let mut out = Discovery {
            agent: agent.into(),
            status: Confidence::Unavailable,
            roots: roots.clone(),
            installation_evidence: self.profile.installation(agent),
            sources: Vec::new(),
            limited: false,
            errors: Vec::new(),
            probe_bytes: 0,
        };
        let start = Instant::now();
        let mut visited = 0;
        let mut paths = std::collections::BTreeSet::new();
        for root in &roots {
            if safe_root(root, &self.profile).is_err() {
                out.errors.push("SOURCE_ROOT_DENIED".into());
                continue;
            }
            if !root.exists() {
                continue;
            }
            let mut stack = vec![(root.clone(), 0)];
            while let Some((path, depth)) = stack.pop() {
                if cancel.load(Ordering::Relaxed)
                    || visited >= self.max_entries
                    || out.sources.len() >= self.max_sources
                    || start.elapsed() > self.timeout
                {
                    out.limited = true;
                    break;
                }
                visited += 1;
                let Ok(m) = fs::symlink_metadata(&path) else {
                    out.errors.push("METADATA_UNAVAILABLE".into());
                    continue;
                };
                if io::is_reparse(&m) {
                    continue;
                }
                if m.is_dir() {
                    if depth >= 6 {
                        out.limited = true;
                        continue;
                    }
                    if let Ok(entries) = fs::read_dir(&path) {
                        for e in entries.flatten() {
                            stack.push((e.path(), depth + 1));
                        }
                    }
                    continue;
                }
                if !m.is_file() || !matches(agent, &path) || !paths.insert(path.clone()) {
                    continue;
                }
                let Ok((file, snapshot)) = io::open_read(&path) else {
                    out.errors
                        .push("READ_PERMISSION_OR_SOURCE_UNAVAILABLE".into());
                    continue;
                };
                let source_id = hash(&format!(
                    "{agent}:{}:{}:{}",
                    snapshot.identity.volume, snapshot.identity.file_id, snapshot.identity.created
                ));
                let mut confidence = Confidence::Probable;
                let mut schema_keys = Vec::new();
                let mut state = ParserState::default();
                let mut c = ParseContext::fixture(agent, &path.to_string_lossy());
                c.kimi_session = path
                    .parent()
                    .and_then(|p| p.file_name())
                    .map(|n| n.to_string_lossy().into_owned());
                let mut reader = BufReader::with_capacity(64 * 1024, file);
                let mut line = Vec::new();
                let mut amount = 0usize;
                // Probe ONLY a bounded prefix. Discovery confidence is upgraded by ingest, not guessed.
                while self.probe
                    && ["codex", "claude-code", "kimi-cli", "pi", "workbuddy"].contains(&agent)
                    && amount < 512 * 1024
                    && start.elapsed() < self.timeout
                {
                    line.clear();
                    let n = reader
                        .by_ref()
                        .take(512 * 1024 - amount as u64)
                        .read_until(b'\n', &mut line)?;
                    if n == 0 {
                        break;
                    }
                    amount += n;
                    out.probe_bytes += n as u64;
                    if line.last() != Some(&10) {
                        break;
                    }
                    if let Ok(Some(_)) = parser.parse(&line, &mut state, &c) {
                        confidence = Confidence::Confirmed;
                        schema_keys = vec!["timestamp".into(), "identity".into(), "usage".into()];
                        break;
                    }
                }
                out.sources.push(SourceDescriptor {
                    agent: agent.into(),
                    source_id,
                    source_kind: if cfg!(windows) {
                        "WindowsNative"
                    } else {
                        "NativeFixture"
                    }
                    .into(),
                    path,
                    root: root.clone(),
                    format: match agent {
                        "deepseek-harness" | "opencode" | "antigravity" | "antigravity-ide" => {
                            "SQLITE_METADATA"
                        }
                        "gemini" => "SESSION_JSON",
                        "cline" => "TASK_UI_JSON",
                        _ => "UTF8_JSONL",
                    }
                    .into(),
                    parser_version: parser.version().into(),
                    source_schema_version: match agent {
                        "codex" => "codex-session-request-or-cumulative",
                        "claude-code" => "claude-assistant-message-usage",
                        "kimi-cli" => "kimi-wire-1.x",
                        "pi" => "pi-session-v3",
                        "workbuddy" => "workbuddy-sdk-usage-v1",
                        "deepseek-harness" => "dsh-ledger-schema4",
                        "gemini" => "gemini-session-v2.0.1",
                        "qwen" => "qwen-monthly-ledger-schema1",
                        "cline" => "cline-historical-task-ui-v1",
                        "opencode" => "opencode-message-sqlite-v1",
                        _ => "antigravity-generation-protobuf-v1",
                    }
                    .into(),
                    confidence,
                    read_mode: "read_only_shared".into(),
                    snapshot,
                    schema_keys,
                });
            }
        }
        out.sources.sort_by(|a, b| a.path.cmp(&b.path));
        out.status = if out
            .sources
            .iter()
            .any(|s| s.confidence == Confidence::Confirmed)
        {
            Confidence::Confirmed
        } else if !out.sources.is_empty() {
            Confidence::Probable
        } else {
            Confidence::Unavailable
        };
        Ok(out)
    }
}
// Kimi working-directory metadata only. Unknown fields (credentials/content) are never materialized.
#[derive(Deserialize)]
struct KimiWorkDirs {
    work_dirs: Vec<KimiDir>,
}
#[derive(Deserialize)]
struct KimiDir {
    path: String,
    kaos: Option<String>,
}
pub fn kimi_directories(profile: &Profile) -> std::collections::BTreeMap<String, String> {
    let mut out = std::collections::BTreeMap::new();
    let path = profile.home.join(".kimi/kimi.json");
    if let Ok((mut file, s)) = io::open_read(&path) {
        if s.size <= 2 * 1024 * 1024 {
            use std::io::Read;
            let mut data = Vec::new();
            if file.read_to_end(&mut data).is_ok() {
                if let Ok(m) = serde_json::from_slice::<KimiWorkDirs>(&data) {
                    for row in m.work_dirs {
                        if row.kaos.as_deref().unwrap_or("local") == "local" {
                            let key = format!("{:x}", md5::compute(row.path.as_bytes()));
                            out.insert(key, row.path);
                        }
                    }
                }
            }
        }
    }
    out
}
