#!/usr/bin/env python3
"""Stage anonymous fixtures in an owned test home; never touch real Agent data."""
import datetime
import json
import pathlib
import shutil

repo = pathlib.Path(__file__).resolve().parents[1]
target = repo / '.build' / 'e2e'
if target.exists():
    shutil.rmtree(target)
target.mkdir(parents=True)
fixtures = repo / 'Tests' / 'AgentBarBarCoreTests' / 'Fixtures'
now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=10)
for source, destination in [
    ('codex-request.jsonl', '.codex/sessions/rollout-fixture.jsonl'),
    ('claude.jsonl', '.claude/projects/example/session.jsonl'),
    ('pi.jsonl', '.pi/agent/sessions/example/session.jsonl'),
]:
    rows = []
    for i, line in enumerate((fixtures / source).read_text().splitlines()):
        row = json.loads(line)
        row['timestamp'] = (now + datetime.timedelta(seconds=i)).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
        rows.append(row)
    path = target / 'home' / destination
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
custom = target / 'custom'
custom.mkdir()
(custom / 'example.jsonl').write_text(json.dumps({'id': 'custom-request', 'timestamp': now.isoformat(), 'model': 'local/example', 'usage': {'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15}}) + '\n')
binary = target / 'home' / 'bin' / 'future-agent'
binary.parent.mkdir(parents=True, exist_ok=True)
binary.write_text('#!/bin/sh\nexit 0\n')
binary.chmod(0o755)
print('Anonymous fixture home ready.')
