# The form komira does not have yet: komira writes the rows into the
# database table itself, with INSERT INTO ... SELECT (komira-ai/komira#2335).
# It must fail with the line of probe_native_insert.error.txt.
import json
from pathlib import Path

import komira

Path("events.jsonl").write_text(json.dumps({"id": 1, "name": "ana"}) + "\n")

with komira.Session() as s:
    s.register_json("events", "events.jsonl")
    s.sql("INSERT INTO events_copy SELECT id, name FROM events")
