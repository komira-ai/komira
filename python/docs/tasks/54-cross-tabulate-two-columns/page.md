# How do I cross-tabulate two columns?

Count the rows per pair of values: `GROUP BY` both columns for the long form, or one `count(CASE WHEN ...)` per value of the second column for the table form; komira has no `crosstab` yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

Path("tickets.csv").write_text(
    "team,priority\n"
    "web,high\n"
    "web,low\n"
    "web,high\n"
    "api,low\n"
    "api,low\n"
    "data,high\n"
)

# SQL: one count per value of the second column, one row per value of the first.
# A pair that never occurs counts 0.
with komira.Session() as s:
    s.register_csv("tickets", "tickets.csv")
    table = s.sql(
        "SELECT team,"
        " count(CASE WHEN priority = 'high' THEN 1 END) AS high,"
        " count(CASE WHEN priority = 'low' THEN 1 END) AS low"
        " FROM tickets GROUP BY team ORDER BY team"
    )
    print(table.to_arrow().to_pylist())

    # The long form: one row per pair that occurs.
    pairs = s.sql(
        "SELECT team, priority, count(*) AS n FROM tickets"
        " GROUP BY team, priority ORDER BY team, priority"
    )
    print(pairs.to_arrow().to_pylist())

# pandas-shaped: the long form, one row per pair.
df = komira.read_csv("tickets.csv")
pairs = df.groupby(["team", "priority"]).agg(n=("priority", "count"))
print(pairs.sort_values(["team", "priority"]).materialize().to_arrow().to_pylist())

# polars-shaped: the wide form with when/then/otherwise.
high = pl.when(pl.col("priority") == "high").then(1).otherwise(0)
low = pl.when(pl.col("priority") == "low").then(1).otherwise(0)
wide = (
    pl.scan_csv("tickets.csv")
    .group_by("team")
    .agg(high.sum().alias("high"), low.sum().alias("low"))
    .sort("team")
    .collect()
)
print(wide.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'team': 'api', 'high': 0, 'low': 2}, {'team': 'data', 'high': 1, 'low': 0}, {'team': 'web', 'high': 2, 'low': 1}]
[{'team': 'api', 'priority': 'low', 'n': 2}, {'team': 'data', 'priority': 'high', 'n': 1}, {'team': 'web', 'priority': 'high', 'n': 2}, {'team': 'web', 'priority': 'low', 'n': 1}]
[{'team': 'api', 'priority': 'low', 'n': 2}, {'team': 'data', 'priority': 'high', 'n': 1}, {'team': 'web', 'priority': 'high', 'n': 2}, {'team': 'web', 'priority': 'low', 'n': 1}]
[{'team': 'api', 'high': 0, 'low': 2}, {'team': 'data', 'high': 1, 'low': 0}, {'team': 'web', 'high': 2, 'low': 1}]
```

## Notes

- The `CASE` form writes out the values of the second column in the query; komira does not discover them from the data. A pair that never occurs counts 0.
- `count(CASE WHEN ... THEN 1 END)` ignores the rows where the condition is false, because `CASE` without `ELSE` gives NULL and `count` skips NULL.
- The long form lists only the pairs that occur; the table form also shows the pairs that do not, as 0.
- komira has no `crosstab` function yet: `probe_crosstab.py` beside this page tries `komira.crosstab` and must fail with the line in `probe_crosstab.error.txt`: komira-ai/komira#2400. The day it runs, this page's check goes red, and the page and the catalogue status change with it.

## Related

- [How do I make a pivot table?](../51-make-pivot-table/page.md) (rank 51, partial)
- [How do I reshape long data to wide?](../53-reshape-long-data-wide/page.md) (rank 53, partial)
- How do I count how many times each value appears? (rank 9, works; no page yet)
- How do I count rows per group? (rank 35, works; no page yet)
