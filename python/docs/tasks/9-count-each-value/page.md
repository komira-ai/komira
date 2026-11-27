# How do I count how many times each value appears?

Group by the column and count the rows: `GROUP BY` with `count(*)` in SQL, `df.groupby("city").size()` on a pandas-shaped frame, or `group_by("city").len()` on a polars-shaped one; then sort the counts.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

Path("visits.csv").write_text(
    "visit_id,city\n"
    "1,Oslo\n"
    "2,Lima\n"
    "3,Oslo\n"
    "4,Pune\n"
    "5,Lima\n"
    "6,Oslo\n"
    "7,Rome\n"
)

# SQL: GROUP BY the column, count(*) the rows. Pune and Rome both appear once,
# so the city is a second sort key and the order is fixed.
with komira.Session() as s:
    s.register_csv("visits", "visits.csv")
    counts = s.sql(
        "SELECT city, count(*) AS n FROM visits"
        " GROUP BY city ORDER BY n DESC, city"
    )
    print(counts.to_arrow().to_pylist())

# pandas-shaped: groupby(...).size() counts the rows of each group in a
# column named size.
df = komira.read_csv("visits.csv")
sizes = df.groupby("city").size().sort_values(["size", "city"], ascending=[False, True])
print(sizes.materialize().to_arrow().to_pylist())

# polars-shaped: group_by(...).len() counts the rows in a column named len.
lf = kpl.scan_csv("visits.csv")
lens = lf.group_by("city").len().sort("len", "city", descending=[True, False])
print(lens.collect().to_arrow().to_pylist())

# pandas' value_counts is refused, and the message says what to write.
try:
    df["city"].value_counts()
except AttributeError as e:
    print(e)
```

Output:

<!-- include expected_output.txt -->
```text
[{'city': 'Oslo', 'n': 3}, {'city': 'Lima', 'n': 2}, {'city': 'Pune', 'n': 1}, {'city': 'Rome', 'n': 1}]
[{'city': 'Oslo', 'size': 3}, {'city': 'Lima', 'size': 2}, {'city': 'Pune', 'size': 1}, {'city': 'Rome', 'size': 1}]
[{'city': 'Oslo', 'len': 3}, {'city': 'Lima', 'len': 2}, {'city': 'Pune', 'len': 1}, {'city': 'Rome', 'len': 1}]
.value_counts() gives a Series indexed by the values in pandas, and a komira Series has no index: count the rows per value with df.groupby(column).size(), and sort them with sort_values("size", ascending=False)
```

## Notes

- `groupby(column).size()` counts the rows of each group in a column named `size`; the polars-shaped `group_by(column).len()` names it `len` (an `Int64`, where polars gives `UInt32`). In SQL, `count(*)` takes the name you give it.
- Sort the counts: no `GROUP BY` promises a row order. Rows with the same count have no promised order among themselves, so add the value as a second sort key, as the example does.
- `size` counts every row of a group. `count` counts the rows where a column is not missing, and `nunique` the distinct values.
- A pandas-shaped `groupby` leaves out the rows whose value is missing (`dropna=False` keeps them as one group); SQL and the polars-shaped `group_by` count NULL as a value of its own.
- `Series.value_counts` is refused: a pandas `value_counts` gives a Series indexed by the values, and a komira Series has no index. The message, printed last in the example, names the spelling to use.

## Related

- [How do I group by a column and sum another column?](../4-group-by-column-and-sum/page.md) (rank 4, works)
- [How do I sort rows by one or more columns?](../8-sort-rows-by-columns/page.md) (rank 8, works)
- [How do I remove duplicate rows?](../13-remove-duplicate-rows/page.md) (rank 13, partial)
- How do I compute several aggregates at once with named outputs? (rank 25, works; no page yet)
