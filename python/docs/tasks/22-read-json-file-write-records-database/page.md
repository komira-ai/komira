# How do I read a JSON file and write the records to a database?

Read the JSON Lines file with komira (`register_json` and SQL), take the rows as Arrow, and insert them with the database's own driver; `sqlite3` ships with Python.

```python
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
```

Output:

```text
4 3
(1, 'ana', 'click', 120)
(2, 'bo', 'view', 40)
(3, 'ana', 'view', 75)
(4, 'cy', 'click', None)
('ana', 2, 120)
('bo', 1, 40)
('cy', 1, None)
```

## Notes

- komira reads newline-delimited JSON (one object per line) with flat values today. A file that is one array of records, or records with nested objects, is not read yet: komira-ai/komira#2338.
- komira has no database connector yet, so the write goes through the driver: komira-ai/komira#2335 tracks writing to a database table from komira itself.
- Postgres is the same shape with `psycopg` (`pip install psycopg`), not run by this page's test:

  ```python
  import psycopg

  with psycopg.connect("dbname=app") as conn:
      with conn.cursor() as cur:
          cur.execute("CREATE TABLE events (id bigint PRIMARY KEY, name text, kind text, ms bigint)")
          cur.executemany(
              "INSERT INTO events VALUES (%(id)s, %(name)s, %(kind)s, %(ms)s)",
              rows.to_pylist(),
          )
  ```

## Related

- How do I read a JSON file into a table? (rank 14, partial; no page yet)
- How do I write a DataFrame to a database table? (rank 21, gap; no page yet)
- How do I flatten nested JSON into columns? (rank 45, gap; no page yet)
- How do I append rows to an existing database table? (rank 88, gap; no page yet)
