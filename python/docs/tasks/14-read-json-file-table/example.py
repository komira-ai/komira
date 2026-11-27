import json
from pathlib import Path

import komira
import komira.pl as pl

# A JSON Lines file: one flat object per line. A key a record lacks reads as NULL.
people = [
    {"id": 1, "name": "ana", "score": 9.5},
    {"id": 2, "name": "bo", "score": 7.0},
    {"id": 3, "name": "cy"},
]
Path("people.jsonl").write_text("".join(json.dumps(p) + "\n" for p in people))

# pandas-shaped: read_json(lines=True) is a plan; materialize() runs it.
df = komira.read_json("people.jsonl", lines=True)
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# SQL: register the file as a table, then query it.
with komira.Session() as s:
    s.register_json("people", "people.jsonl")
    table = s.sql("SELECT id, name, score FROM people ORDER BY id").to_arrow()
    print(table.to_pylist())
    print(s.sql("SELECT count(*) AS n, max(score) AS best FROM people").to_arrow().to_pylist())

# polars-shaped: scan_ndjson is lazy; collect() runs it.
print(pl.scan_ndjson("people.jsonl").sort("id").collect().to_arrow().to_pylist())
