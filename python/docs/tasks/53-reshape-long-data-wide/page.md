# How do I reshape long data to wide?

In SQL, `PIVOT (max(score) FOR quarter IN ('q1', 'q2', 'q3'))` makes one column per listed value, grouped by the other columns; on the pandas-shaped frame, merge one filtered frame per new column. komira has no pandas-shaped `pivot` yet.

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

# SQL PIVOT: one column per listed quarter, one row per name. A name with
# no row for a quarter gets NULL.
with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    wide = s.sql(
        "SELECT * FROM scores PIVOT (max(score) FOR quarter IN ('q1', 'q2', 'q3'))"
        " ORDER BY name"
    )
    print(wide.to_arrow().to_pylist())

    # The same table by hand: one aggregate over CASE WHEN per new column,
    # grouped by the row key.
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
[{'name': 'Ana', 'q1': 10, 'q2': 20, 'q3': 30}, {'name': 'Bo', 'q1': 5, 'q2': None, 'q3': 7}, {'name': 'Cy', 'q1': 1, 'q2': 2, 'q3': None}]
```

## Notes

- `PIVOT` groups by every column it does not name (`name`; `quarter` is the FOR column and `score` is inside the aggregate) and names each new column by its value. A name with no row for a quarter gets NULL (`Bo` has no `q2`, `Cy` has no `q3`). With more than one row per name and quarter, use `sum` or another aggregate in place of `max`.
- The new column names are the values listed after `IN`; komira does not read them from the data, so the statement form `PIVOT scores ON quarter USING max(score)` is refused. The value pivoted must be a BIGINT or a DOUBLE: over a text value, `max` is refused by name.
- `max(CASE WHEN quarter = 'q1' THEN score END)` per column is the same table by hand. An aggregate's `FILTER (WHERE ...)` clause is refused today, so `CASE WHEN` is the form to use there.
- The pandas-shaped form starts from the distinct row keys and does a left `merge` of each quarter's rows, so a missing quarter is a null too. komira has no pandas-shaped `pivot` that reads the columns from the data yet: komira-ai/komira#2400. `probe_pivot_method.py` beside this page tries it and must fail with the line in `probe_pivot_method.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I make a pivot table?](../51-make-pivot-table/page.md) (rank 51, partial)
- [How do I melt (unpivot) wide data to long?](../52-melt-wide-data-long/page.md) (rank 52, partial)
- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
