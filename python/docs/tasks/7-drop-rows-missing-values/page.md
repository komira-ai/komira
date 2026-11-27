# How do I drop rows with missing values?

Keep the rows with `WHERE column IS NOT NULL` in SQL, or call `dropna()` on the pandas-shaped frame or `drop_nulls()` on the polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as kpl

# A small CSV file: an empty field reads as NULL.
Path("people.csv").write_text(
    "id,name,score,city\n"
    "1,Ana,9.5,Oslo\n"
    "2,Bo,,Lima\n"
    "3,,7.0,\n"
    "4,,,Rome\n"
    "5,,,\n"
)

# SQL: keep the rows whose values are not NULL.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    complete = s.sql(
        "SELECT * FROM people"
        " WHERE name IS NOT NULL AND score IS NOT NULL AND city IS NOT NULL"
    )
    print(complete.to_arrow().to_pylist())
    scored = s.sql("SELECT * FROM people WHERE score IS NOT NULL ORDER BY id")
    print(scored.to_arrow().to_pylist())
    either = s.sql(
        "SELECT id FROM people WHERE name IS NOT NULL OR score IS NOT NULL ORDER BY id"
    )
    print(either.to_arrow().to_pylist())

# pandas-shaped: dropna keeps the rows with no missing value, or with none in
# the columns of subset=, or (how="all") with a value in at least one of them.
df = komira.read_csv("people.csv")
print(df.dropna().materialize().to_arrow().to_pylist())
print(df.dropna(subset=["score"]).sort_values("id").materialize().to_arrow().to_pylist())
any_value = df.dropna(how="all", subset=["name", "score"])[["id"]]
print(any_value.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: drop_nulls, with a column name or a list of them for a subset.
lf = kpl.scan_csv("people.csv")
print(lf.drop_nulls().collect().to_arrow().to_pylist())
print(lf.drop_nulls("score").sort("id").collect().to_arrow().to_pylist())

# NaN in a float column is missing too in the pandas-shaped frame, as NULL is.
pq.write_table(pa.table({"id": [1, 2, 3], "x": [1.5, float("nan"), None]}), "x.parquet")
print(komira.read_parquet("x.parquet").dropna().materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'id': 1, 'name': 'Ana', 'score': 9.5, 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'score': 9.5, 'city': 'Oslo'}, {'id': 3, 'name': None, 'score': 7.0, 'city': None}]
[{'id': 1}, {'id': 2}, {'id': 3}]
[{'id': 1, 'name': 'Ana', 'score': 9.5, 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'score': 9.5, 'city': 'Oslo'}, {'id': 3, 'name': None, 'score': 7.0, 'city': None}]
[{'id': 1}, {'id': 2}, {'id': 3}]
[{'id': 1, 'name': 'Ana', 'score': 9.5, 'city': 'Oslo'}]
[{'id': 1, 'name': 'Ana', 'score': 9.5, 'city': 'Oslo'}, {'id': 3, 'name': None, 'score': 7.0, 'city': None}]
[{'id': 1, 'x': 1.5}]
```

## Notes

- A missing value is NULL, and an empty CSV field reads as NULL. On the pandas-shaped frame a NaN in a float column is missing too, so `dropna()` drops it; on the polars-shaped frame `drop_nulls()` drops NULL only, and a NaN is a value. In SQL a NaN is a value as well.
- `dropna()` drops a row with a missing value in any column. `subset=` names the columns to look at, as a name or a list of names, and `how="all"` drops a row only when every one of them is missing. In SQL, `AND` of the `IS NOT NULL` tests is `how="any"` and `OR` is `how="all"`.
- `thresh=` is refused with `UnsupportedOperation`; for `thresh=2` the message is `dropna(thresh=2) counts the values each row holds, which this release does not build: use how="any" or how="all", or name the columns with subset=`.
- `dropna(axis=1)` and `inplace=True` are refused too: choose the columns you keep with `df[[...]]`, and use the frame `dropna` returns.
- `drop_nulls` takes a column name or a list of names and has no `how` or `thresh`.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- [How do I find and fill missing values?](../6-find-fill-missing-values/page.md) (rank 6, works)
- How do I replace specific values such as 'N/A' with null? (rank 55, works; no page yet)
- [How do I remove duplicate rows?](../13-remove-duplicate-rows/page.md) (rank 13, partial)
- How do I validate data: nulls, uniqueness, ranges? (rank 59, works; no page yet)
