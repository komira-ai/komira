# How do I melt (unpivot) wide data to long?

Call `df.melt(id_vars=..., var_name=..., value_name=...)` on the pandas-shaped frame or `lf.unpivot(on, index=..., variable_name=..., value_name=...)` on `komira.pl`, which name the columns once; in SQL, stack one `SELECT` per column with `UNION ALL`, since komira has no `UNPIVOT` yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

Path("scores.csv").write_text(
    "name,q1,q2,q3\n"
    "Ana,10,20,30\n"
    "Bo,5,,7\n"
    "Cy,1,2,3\n"
)

# SQL: one SELECT per column to melt, stacked with UNION ALL.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    long = s.sql(
        "SELECT name, 'q1' AS quarter, q1 AS score FROM scores"
        " UNION ALL SELECT name, 'q2', q2 FROM scores"
        " UNION ALL SELECT name, 'q3', q3 FROM scores"
        " ORDER BY name, quarter"
    )
    print(long.to_arrow().to_pylist())

# pandas-shaped: melt, every column not in id_vars becoming rows.
df = komira.read_csv("scores.csv")
long = df.melt(id_vars=["name"], var_name="quarter", value_name="score")
print(long.sort_values(["name", "quarter"]).materialize().to_arrow().to_pylist())

# polars-shaped: unpivot, the same with polars' names.
lf = pl.scan_csv("scores.csv")
long = lf.unpivot(["q1", "q2", "q3"], index="name", variable_name="quarter", value_name="score")
print(long.sort("name", "quarter").collect().to_arrow().to_pylist())

# Without the missing scores: drop the rows whose score is missing.
print(long.drop_nulls("score").sort("name", "quarter").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q2', 'score': None}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q2', 'score': None}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q2', 'score': None}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
```

## Notes

- `melt` turns every column not in `id_vars` into rows when `value_vars` is left out; `unpivot` does the same for every column not in `index` when `on` is None. The new columns are named `variable` and `value` unless `var_name` and `value_name` (`variable_name` and `value_name` in `komira.pl`) say otherwise. `komira.melt(df, ...)` is the same as `df.melt(...)`.
- The melted columns must be of one type: pandas would make an object column of an int and a float, and polars would cast them to a common type, while komira refuses them by name; cast them first with `astype` or `cast`.
- A missing value stays a row with a missing score (`Bo`, `q2`), as in pandas and polars. Drop those rows with `dropna(subset=["score"])` or `drop_nulls("score")`, or in SQL with `WHERE score IS NOT NULL`.
- In SQL the label of each column is a literal you write, so the column list is spelled out in the query: komira has no `UNPIVOT` clause yet (komira-ai/komira#2399). `probe_unpivot.py` beside this page tries it and must fail with the line in `probe_unpivot.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY`, `sort_values` or `sort`.

## Related

- [How do I make a pivot table?](../51-make-pivot-table/page.md) (rank 51, partial)
- [How do I reshape long data to wide?](../53-reshape-long-data-wide/page.md) (rank 53, partial)
- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
