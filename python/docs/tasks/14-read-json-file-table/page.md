# How do I read a JSON file into a table?

Read the JSON Lines file (one object per line) with `komira.read_json(path, lines=True)`, with SQL after `Session.register_json`, or with `komira.pl.scan_ndjson`.

<!-- include example.py -->
```python
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
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'ana', 'score': 9.5}, {'id': 2, 'name': 'bo', 'score': 7.0}, {'id': 3, 'name': 'cy', 'score': None}]
[{'id': 1, 'name': 'ana', 'score': 9.5}, {'id': 2, 'name': 'bo', 'score': 7.0}, {'id': 3, 'name': 'cy', 'score': None}]
[{'n': 3, 'best': 9.5}]
[{'id': 1, 'name': 'ana', 'score': 9.5}, {'id': 2, 'name': 'bo', 'score': 7.0}, {'id': 3, 'name': 'cy', 'score': None}]
```

## Notes

- komira reads newline-delimited JSON (JSON Lines) with flat values today. The engine infers column names and types from the start of the file; the rows are read when a query runs. A key a record lacks reads as NULL.
- In SQL, `read_json('file.jsonl')`, `read_json_auto(...)`, `read_ndjson(...)` and a bare `FROM 'file.jsonl'` read the same files as `register_json`.
- A file that is one JSON array of records (`[{...}, {...}]`, what pandas `read_json` reads by default) is not read: `read_json` without `lines=True` is refused, and SQL `read_json(..., format='array')` is refused by name. `probe_array_file.py` beside this page tries it and must fail with the line in `probe_array_file.error.txt`. Tracked by komira-ai/komira#2338.
- Records with nested objects or arrays are not read into struct or list columns: schema inference refuses them. `probe_nested_objects.py` tries it and must fail with the line in `probe_nested_objects.error.txt`. Tracked by komira-ai/komira#2338.
- The day a probe runs to the end, this page's check goes red, and the page and the catalogue status change with it.
- `komira.pl` has `scan_ndjson` only; there is no eager `read_ndjson` or `read_json`, so run the lazy frame with `.collect()`.

## Related

- [How do I read a CSV file?](../1-read-csv-file/page.md) (rank 1, works)
- [How do I read a Parquet file?](../15-read-parquet-file/page.md) (rank 15, works)
- How do I flatten nested JSON into columns? (rank 45, gap; no page yet)
- [How do I read a JSON file and write the records to a database?](../22-read-json-file-write-records-database/page.md) (rank 22, partial)
