# Collector support

Collector availability depends on operating system, installed Agent version, and the local files that exist. Discovery alone does not mean usage is available. The app reports source state and metric coverage separately.

| Agent source | Local format used by the collector | Notes |
|---|---|---|
| OpenAI Codex | Session/request JSONL | Request records are deduplicated by reported identity; legacy snapshots have partial-history limits. |
| Claude Code CLI | `.claude/projects` JSONL | Uses reported request-level usage and message identity. |
| Claude Desktop Code tab | Shared Claude Code request stream | Uses the reported entrypoint when available; shared requests are counted once. |
| Gemini CLI | Session JSON / JSONL | Parser behavior is versioned by format. |
| Qwen Code | Monthly token ledger JSONL | Reads reported ledger counters. |
| Cline | Task UI JSON metadata | Reads recognized request usage metadata only. |
| Pi | Session JSONL | Reads reported model usage and excludes failed all-zero placeholders. |
| Kimi CLI | Wire JSONL | Model/provider may remain unknown when the source does not report them. |
| DeepSeek Harness | SQLite usage ledger; legacy compressed JSONL where supported | The authoritative ledger takes precedence over duplicate session records. |
| OpenCode | Local SQLite database | Reads recognized completed-request metadata. |
| WorkBuddy | Persisted SDK JSONL | Deduplicates carriers with the same reported request identity. |
| Antigravity and Antigravity IDE | SQLite/protobuf generation metadata | Reads reported generation counters. |

**Claude Desktop standard chat and Cowork are not usage-supported.** The current code has inspection-only handling for those surfaces; no verified request-level local token source is available, so they are excluded from totals. Do not interpret that as proof that no upstream format could ever expose such data.

Other discovered applications may appear as detected but unsupported. A parser change or a newly verified source must update its version, anonymous fixtures, tests, and this page. Platform-specific implementation and runtime availability may differ; check the app's source-coverage view on the target machine.
