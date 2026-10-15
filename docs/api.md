# macOS local API v1

The macOS app serves the bundled dashboard and API from `http://127.0.0.1:<dynamic-port>`. It does not bind a public interface. The TypeScript contract is `Dashboard/src/schema.ts`; the normalized event schema is `Shared/usage-event.schema.json`.

## Authentication

The app creates a random per-launch HttpOnly, SameSite Strict cookie for the dashboard. API requests require that cookie or a bearer credential from the private runtime file. CORS is disabled; Host must match the current loopback origin. Mutations also require a matching browser Origin and `X-AgentBarBar: 1`. The app bounds request bodies and headers. Source content is never served.

## Read endpoints

| Endpoint | Result |
|---|---|
| `/health` | Minimal service availability. |
| `/api/status` | Schema, local database path, collection state, time zone, and native-settings capability. |
| `/api/overview` | Summary, calendar windows, timeline, Agent/model distributions. |
| `/api/summary` | Nullable metrics, event coverage, and unique session/Agent/project counts. |
| `/api/agents` | Discovery evidence, usage, collector health/capabilities, models, and last activity. |
| `/api/models` | Groups by raw model identifier. |
| `/api/projects` | Groups by identified project. |
| `/api/sessions` | Session groups with Agent/model/project context. |
| `/api/events` | Paginated metadata provenance. |
| `/api/filters` | Agent/model/project/provider filter options. |
| `/api/collectors` | Collector descriptor, discovery, last run, and errors. |
| `/api/settings` | Local preferences, mappings, and source overrides. |

Statistical endpoints share `start`, `end`, `agent`, `model`, `project`, `provider`, `session`, and `tz` filters. Date ranges use ISO 8601 instants and an exclusive end. `unknown` selects missing model/project/provider/session values. Timeline buckets use calendar boundaries, including daylight-saving transitions.

## Mutations

- `POST /api/sync` schedules a collection run; concurrent requests are coalesced.
- `POST /api/settings` validates and stores local settings, updates the collector registry, and schedules collection.
- `POST /api/native-settings` opens native settings when supported by the running app.

Windows uses Tauri IPC for the dashboard host rather than this macOS HTTP service. Both platforms share the normalized usage-event contract.
