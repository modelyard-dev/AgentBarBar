#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
swift test
.build/debug/agentbarbar-cli --help
cd Dashboard
npm ci --no-fund --no-audit
npm run build
npm test
npm run test:e2e
