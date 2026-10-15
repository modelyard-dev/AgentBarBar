# Contributing

Thanks for helping improve AgentBarBar. Start with the [documentation index](docs/README.md) and [development guide](docs/development.md).

## Privacy requirements

- Treat third-party Agent directories and databases as read-only. Do not change their settings, transcripts, databases, or credentials.
- Never commit prompts, replies, conversation bodies, tool arguments, source code copied from user sessions, credentials, runtime databases, or raw transcript lines.
- Fixtures must be anonymous metadata. Replace identities and paths, and retain only fields needed to exercise parser behavior.
- Missing, unsupported, and unavailable metrics must remain nullable and carry an explicit state. Never substitute zero.
- Keep collection bounded, version parsers when formats change, and update the source support documentation when support or validation changes.

## Changes

- Keep platform code in its platform directory and shared contracts in `Shared/` and `Dashboard/`.
- Add or update focused tests for behavioral changes. Use synthetic fixtures where possible.
- Update `CHANGELOG.md` for user-visible code, collector, UI, configuration, documentation, sync, or release-process changes. State affected platforms and actual versions/builds; do not infer a version from another platform.
- Do not commit `.build/`, `build/`, `target/`, dashboard output/dependencies, app databases, credentials, or `.dmg`/`.exe`/`.msi` installers.
- Keep third-party sources and notices under their existing licenses. Do not replace upstream license files with the project license.

## Pull requests

Describe the affected platform, behavior, verification performed, and any platform or source-format limits. Do not attach real Agent logs or screenshots containing local usage data.

The MIT license applies to AgentBarBar's original work. Files under `ThirdParty/` and bundled dependency notices retain their own licenses; see `ThirdParty/zstd/LICENSE` and `assets/THIRD_PARTY_NOTICES.txt`.
