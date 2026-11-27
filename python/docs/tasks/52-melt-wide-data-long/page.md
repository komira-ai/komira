# How do I melt (unpivot) wide data to long?

In SQL, `UNPIVOT (score FOR quarter IN (q1, q2, q3))` turns the listed columns into a name column and a value column; on the pandas-shaped frame, `komira.concat` one frame per column. komira has no pandas-shaped `melt` yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("scores.csv").write_text(
    "name,q1,q2,q3\n"
    "Ana,10,20,30\n"
    "Bo,5,,7\n"
    "Cy,1,2,3\n"
)

# SQL UNPIVOT: one row per name and quarter; a NULL score is left out.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    long = s.sql(
        "SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1, q2, q3))"
        " ORDER BY name, quarter"
    )
    print(long.to_arrow().to_pylist())

    # The same rows by hand: one SELECT per column, stacked with UNION ALL,
    # which keeps the NULL score.
    long = s.sql(
        "SELECT name, 'q1' AS quarter, q1 AS score FROM scores"
        " UNION ALL SELECT name, 'q2', q2 FROM scores"
        " UNION ALL SELECT name, 'q3', q3 FROM scores"
        " ORDER BY name, quarter"
    )
    print(long.to_arrow().to_pylist())

# pandas-shaped: one frame per column, stacked with concat.
df = komira.read_csv("scores.csv")
parts = [
    df.assign(quarter=col, score=df[col])[["name", "quarter", "score"]]
    for col in ["q1", "q2", "q3"]
]
long = komira.concat(parts)
print(long.dropna(subset=["score"]).sort_values(["name", "quarter"]).materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q2', 'score': None}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
```

## Notes

- `UNPIVOT` keeps every column it does not list (`name`), then adds the name column (`quarter`, holding `'q1'`, `'q2'`, `'q3'`) and the value column (`score`). `q1 AS 'first'` writes `first` in place of the column name. The listed columns must have one type.
- A NULL value is left out (`Bo` has no `q2` row); `UNPIVOT INCLUDE NULLS (...)` keeps it, as the `UNION ALL` form does. The pandas-shaped form drops those rows with `dropna(subset=["score"])`.
- komira has no pandas-shaped `melt` that takes the column names yet: komira-ai/komira#2400. `probe_melt.py` beside this page tries it and must fail with the line in `probe_melt.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I make a pivot table?](../51-make-pivot-table/page.md) (rank 51, partial)
- [How do I reshape long data to wide?](../53-reshape-long-data-wide/page.md) (rank 53, partial)
- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- [How do I rename columns?](../16-rename-columns/page.md) (rank 16, works)
