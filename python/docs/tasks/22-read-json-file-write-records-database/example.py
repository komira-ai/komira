import json
import sqlite3
from pathlib import Path

import komira

# A JSON Lines file: one object per line. A key a record lacks reads as NULL.
events = [
    {"id": 1, "name": "ana", "kind": "click", "ms": 120},
    {"id": 2, "name": "bo", "kind": "view", "ms": 40},
    {"id": 3, "name": "ana", "kind": "view", "ms": 75},
    {"id": 4, "name": "cy", "kind": "click"},
]
Path("events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))

with komira.Session() as s:
    s.register_json("events", "events.jsonl")
    rows = s.sql("SELECT id, name, kind, ms FROM events ORDER BY id").to_arrow()
    per_name = s.sql(
        "SELECT name, count(*) AS events, max(ms) AS slowest"
        " FROM events GROUP BY name ORDER BY name"
    ).to_arrow()
print(rows.num_rows, per_name.num_rows)

# komira hands back Arrow; the database's own driver writes it. sqlite3
# ships with Python, and a list of dicts binds to named parameters.
db = sqlite3.connect("events.db")
db.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, kind TEXT, ms INTEGER)")
db.executemany("INSERT INTO events VALUES (:id, :name, :kind, :ms)", rows.to_pylist())
db.execute("CREATE TABLE per_name (name TEXT PRIMARY KEY, events INTEGER, slowest INTEGER)")
db.executemany("INSERT INTO per_name VALUES (:name, :events, :slowest)", per_name.to_pylist())
db.commit()

for row in db.execute("SELECT * FROM events ORDER BY id"):
    print(row)
for row in db.execute("SELECT * FROM per_name ORDER BY name"):
    print(row)
db.close()
