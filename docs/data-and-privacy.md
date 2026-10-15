# Data and privacy

AgentBarBar is designed to process supported Agent usage data locally.

## What it reads and stores

Collectors read recognized local source files or databases without changing them. The app stores reported counters, timestamps, raw model/provider identifiers, session/project metadata, collector status, and source provenance in its app-owned SQLite database. Local project paths may appear in the local database when the source explicitly reports a working directory.

The usage ledger excludes prompts, replies, conversation bodies, tool arguments, source code, and credentials. Errors and diagnostics are designed to report parser/status metadata rather than transcript content. Unsupported and missing metrics stay nullable and are not replaced with zero.

## Network behavior

- Collection and dashboard queries run locally.
- The macOS app can check GitHub Releases for updates. It sends the app version in its HTTP User-Agent and downloads a public installer only after the user chooses it. Collected usage data is not included in the request.
- The Windows app may open the project website or a release link when the user selects one. Collection data is not sent with that action.
- The app does not upload usage telemetry.

## Repository contents

The public repository contains application source, build configuration, documentation, third-party notices, and anonymous metadata-only test fixtures. It excludes user databases, raw Agent logs, transcripts, credentials, machine-specific paths, internal survey reports, release-validation evidence, and generated installers/build output.

When reporting an issue, do not attach local databases, Agent logs, screenshots with usage data, or runtime credential files. A small synthetic fixture with only the fields needed to reproduce a parser issue is preferred.
