# How do I compute each row's percent of its group total?

Take a window `SUM(...) OVER (PARTITION BY group)` in an inner query and divide by it in the outer one, or divide a pandas-shaped column by `groupby(...).transform("sum")`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "region,rep,amount\n"
    "east,Ana,120\n"
    "east,Bo,80\n"
    "west,Cy,50\n"
    "west,Di,150\n"
    "west,Ed,100\n"
    "north,Flo,200\n"
)

# SQL: a window SUM gives each row its group total; a second SELECT divides.
# round(x, 1) keeps one decimal.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    shares = s.sql(
        "SELECT region, rep, amount, round(amount * 100.0 / total, 1) AS pct"
        " FROM (SELECT region, rep, amount,"
        " SUM(amount) OVER (PARTITION BY region) AS total FROM sales)"
        " ORDER BY region, rep"
    )
    print(shares.to_arrow().to_pylist())

# pandas-shaped: divide by the group's transform('sum'), then round to one decimal.
df = komira.read_csv("sales.csv")
df["pct"] = (df["amount"] / df.groupby("region")["amount"].transform("sum") * 100).round(1)
for row in df.sort_values("rep").materialize().to_arrow().to_pylist():
    print(row["rep"], row["pct"])
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'rep': 'Ana', 'amount': 120, 'pct': 60.0}, {'region': 'east', 'rep': 'Bo', 'amount': 80, 'pct': 40.0}, {'region': 'north', 'rep': 'Flo', 'amount': 200, 'pct': 100.0}, {'region': 'west', 'rep': 'Cy', 'amount': 50, 'pct': 16.7}, {'region': 'west', 'rep': 'Di', 'amount': 150, 'pct': 50.0}, {'region': 'west', 'rep': 'Ed', 'amount': 100, 'pct': 33.3}]
Ana 60.0
Bo 40.0
Cy 16.7
Di 50.0
Ed 33.3
Flo 100.0
```

## Notes

- The window total has to be its own SELECT item: komira refuses a window function nested inside an expression, so `amount * 100.0 / SUM(amount) OVER (...)` in one SELECT fails, and the division goes in an outer query (komira-ai/komira#2379). `probe_window_in_expression.py` beside this page tries the one-SELECT form and must fail with the line in `probe_window_in_expression.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- The inner query lists its columns: `SELECT *` next to a window function is refused too (komira-ai/komira#2379).
- The two roundings differ on exact halves: SQL `round(2.5)` is 3, halves away from zero, as DuckDB does; `Series.round` gives 2 for 2.5, halves to even, as pandas does. This example has no exact half, so both print the same values.
- Each row stays: `transform("sum")` and the window both put the group total beside every row, unlike `GROUP BY`, which collapses the rows.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I count rows per group?](../35-count-rows-per-group/page.md) (rank 35, works)
- [How do I compute a running total per group?](../48-compute-running-total-per-group/page.md) (rank 48, works)
- [How do I rank rows within a group?](../49-rank-rows-within-group/page.md) (rank 49, works)
