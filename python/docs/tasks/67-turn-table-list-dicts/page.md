# How do I turn a table into a list of dicts?

Run the query or frame, take the answer as an Arrow table with `to_arrow()`, and call `to_pylist()`: one dict per row.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("people.csv").write_text("id,name,city\n1,Ana,Oslo\n2,Bo,Lima\n3,Cy,Oslo\n")

# SQL: the answer is read into an Arrow table, and to_pylist() makes one dict per row.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    table = s.sql("SELECT id, name FROM people ORDER BY id").to_arrow()
    print(table.to_pylist())

    # The other shape: one list per column.
    print(table.to_pydict())

# pandas-shaped: materialize() runs the frame, then the same call.
df = komira.read_csv("people.csv")
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: collect() runs the frame.
lf = pl.scan_csv("people.csv").sort("id")
print(lf.collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana'}, {'id': 2, 'name': 'Bo'}, {'id': 3, 'name': 'Cy'}]
{'id': [1, 2, 3], 'name': ['Ana', 'Bo', 'Cy']}
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Lima'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'city': 'Oslo'}, {'id': 2, 'name': 'Bo', 'city': 'Lima'}, {'id': 3, 'name': 'Cy', 'city': 'Oslo'}]
```

## Notes

- `Session.sql(...)` returns a `Result` that is read once; `to_arrow()` reads it. Call `to_pylist()` or `to_pydict()` on the Arrow table it returns, and keep the table if you need both.
- A pandas-shaped frame is a plan, not rows: `df.to_arrow()` is refused with a message saying to call it on the `Result` of `materialize()`, and `df.to_dict(...)` and `df.to_records()` are refused as pandas' own (they need `materialize().to_pandas()`, which needs pandas installed). Write `df.materialize().to_arrow().to_pylist()`.
- The polars-shaped frame runs at `collect()`, and the `Result` it returns has the same `to_arrow()`.
- Every dict has the columns of the table, in their order; NULL is `None`. Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.
- `to_pylist()` builds the whole list in memory; for a large answer, filter or `LIMIT` first, or read batches with `Result.to_reader()`.
- `to_pandas().to_dict("records")` and `to_polars().to_dicts()` also work when pandas or polars is installed; the example does not need either.

## Related

- How do I loop over the rows of a table? (rank 68, works)
- How do I take the first or last N rows? (rank 65, works)
- How do I reorder columns? (rank 66, works)
- How do I select or drop columns? (rank 34, works; no page yet)
