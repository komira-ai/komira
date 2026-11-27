# How do I reshape long data to wide?

Group by the row key and take one `max(CASE WHEN ... THEN value END)` per new column in SQL, or merge one filtered frame per new column on the pandas-shaped frame; komira has no `PIVOT` or `pivot` yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("scores.csv").write_text(
    "name,quarter,score\n"
    "Ana,q1,10\n"
    "Ana,q2,20\n"
    "Ana,q3,30\n"
    "Bo,q1,5\n"
    "Bo,q3,7\n"
    "Cy,q1,1\n"
    "Cy,q2,2\n"
)

# SQL: one aggregate over CASE WHEN per new column, grouped by the row key.
# A name with no row for a quarter gets NULL.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    wide = s.sql(
        "SELECT name,"
        " max(CASE WHEN quarter = 'q1' THEN score END) AS q1,"
        " max(CASE WHEN quarter = 'q2' THEN score END) AS q2,"
        " max(CASE WHEN quarter = 'q3' THEN score END) AS q3"
        " FROM scores GROUP BY name ORDER BY name"
    )
    print(wide.to_arrow().to_pylist())

# pandas-shaped: one filtered frame per new column, merged on the row key.
df = komira.read_csv("scores.csv")
wide = df[["name"]].drop_duplicates()
for quarter in ["q1", "q2", "q3"]:
    part = df[df["quarter"] == quarter][["name", "score"]].rename(columns={"score": quarter})
    wide = wide.merge(part, on="name", how="left")
print(wide.sort_values("name").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'name': 'Ana', 'q1': 10, 'q2': 20, 'q3': 30}, {'name': 'Bo', 'q1': 5, 'q2': None, 'q3': 7}, {'name': 'Cy', 'q1': 1, 'q2': 2, 'q3': None}]
[{'name': 'Ana', 'q1': 10, 'q2': 20, 'q3': 30}, {'name': 'Bo', 'q1': 5, 'q2': None, 'q3': 7}, {'name': 'Cy', 'q1': 1, 'q2': 2, 'q3': None}]
```

## Notes

- `max(CASE WHEN quarter = 'q1' THEN score END)` picks the `q1` score of each name, and NULL where the name has no `q1` row (`Bo` has no `q2`, `Cy` has no `q3`). With more than one row per name and quarter, use `sum` or another aggregate in place of `max`.
- The pandas-shaped form starts from the distinct row keys and does a left `merge` of each quarter's rows, so a missing quarter is a null too.
- The new column names are spelled out in the query. komira has no `PIVOT` clause and no `pivot` that reads them from the data: komira-ai/komira#2399 (SQL) and komira-ai/komira#2400 (the frames). `probe_pivot.py` (SQL) and `probe_pivot_method.py` (pandas-shaped) beside this page try those forms and must fail with the lines in `probe_pivot.error.txt` and `probe_pivot_method.error.txt`. The day one of them runs, this page's check goes red, and the page and the catalogue status change with it.
- An aggregate's `FILTER (WHERE ...)` clause is refused today, so `CASE WHEN` is the form to use.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I make a pivot table?](../51-make-pivot-table/page.md) (rank 51, partial)
- [How do I melt (unpivot) wide data to long?](../52-melt-wide-data-long/page.md) (rank 52, partial)
- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
