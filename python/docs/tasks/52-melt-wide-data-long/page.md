# How do I melt (unpivot) wide data to long?

Stack one `SELECT` per column with `UNION ALL` in SQL, or `komira.concat` one frame per column on the pandas-shaped frame; komira has no `UNPIVOT` or `melt` yet.

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
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q2', 'score': None}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
[{'name': 'Ana', 'quarter': 'q1', 'score': 10}, {'name': 'Ana', 'quarter': 'q2', 'score': 20}, {'name': 'Ana', 'quarter': 'q3', 'score': 30}, {'name': 'Bo', 'quarter': 'q1', 'score': 5}, {'name': 'Bo', 'quarter': 'q3', 'score': 7}, {'name': 'Cy', 'quarter': 'q1', 'score': 1}, {'name': 'Cy', 'quarter': 'q2', 'score': 2}, {'name': 'Cy', 'quarter': 'q3', 'score': 3}]
```

## Notes

- Each wide column becomes one `SELECT name, '<column>' AS quarter, <column> AS score`; the label is a literal you write, so the column list is spelled out in the query.
- A missing value stays a row with a NULL score (`Bo`, `q2`). The pandas-shaped form drops those rows with `dropna(subset=["score"])`, which `UNION ALL` leaves to a `WHERE score IS NOT NULL`.
- komira has no `UNPIVOT` clause and no `melt` that takes the column names, so the column list cannot be given once: komira-ai/komira#2399 (SQL) and komira-ai/komira#2400 (the frames). `probe_unpivot.py` (SQL) and `probe_melt.py` (pandas-shaped) beside this page try those forms and must fail with the lines in `probe_unpivot.error.txt` and `probe_melt.error.txt`. The day one of them runs, this page's check goes red, and the page and the catalogue status change with it.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I make a pivot table?](../51-make-pivot-table/page.md) (rank 51, partial)
- [How do I reshape long data to wide?](../53-reshape-long-data-wide/page.md) (rank 53, partial)
- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- How do I rename columns? (rank 16, works; no page yet)
