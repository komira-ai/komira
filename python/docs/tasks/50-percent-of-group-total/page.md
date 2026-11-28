# How do I compute each row's percent of its group total?

Divide by a window `SUM(...) OVER (PARTITION BY group)` in the same SELECT, or divide a pandas-shaped column by `groupby(...).transform("sum")`.

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

# SQL: SUM(amount) OVER (PARTITION BY region) is each row's group total, and
# the division reads it in the same SELECT. Scaling by 1000, rounding and
# dividing by 10 keeps one decimal.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    shares = s.sql(
        "SELECT region, rep, amount,"
        " round(amount * 1000.0 / SUM(amount) OVER (PARTITION BY region)) / 10 AS pct"
        " FROM sales ORDER BY region, rep"
    )
    print(shares.to_arrow().to_pylist())
    # SELECT * beside a window: the table's columns, then the window's.
    totals = s.sql(
        "SELECT *, SUM(amount) OVER (PARTITION BY region) AS total"
        " FROM sales ORDER BY rep"
    )
    print(totals.to_arrow().to_pylist())

# pandas-shaped: divide by the group's transform('sum'), round when printing.
df = komira.read_csv("sales.csv")
df["pct"] = df["amount"] / df.groupby("region")["amount"].transform("sum") * 100
for row in df.sort_values("rep").materialize().to_arrow().to_pylist():
    print(row["rep"], f"{row['pct']:.1f}")
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'rep': 'Ana', 'amount': 120, 'pct': 60.0}, {'region': 'east', 'rep': 'Bo', 'amount': 80, 'pct': 40.0}, {'region': 'north', 'rep': 'Flo', 'amount': 200, 'pct': 100.0}, {'region': 'west', 'rep': 'Cy', 'amount': 50, 'pct': 16.7}, {'region': 'west', 'rep': 'Di', 'amount': 150, 'pct': 50.0}, {'region': 'west', 'rep': 'Ed', 'amount': 100, 'pct': 33.3}]
[{'region': 'east', 'rep': 'Ana', 'amount': 120, 'total': 200}, {'region': 'east', 'rep': 'Bo', 'amount': 80, 'total': 200}, {'region': 'west', 'rep': 'Cy', 'amount': 50, 'total': 300}, {'region': 'west', 'rep': 'Di', 'amount': 150, 'total': 300}, {'region': 'west', 'rep': 'Ed', 'amount': 100, 'total': 300}, {'region': 'north', 'rep': 'Flo', 'amount': 200, 'total': 200}]
Ana 60.0
Bo 40.0
Cy 16.7
Di 50.0
Ed 33.3
Flo 100.0
```

## Notes

- A window function can sit inside any SELECT or ORDER BY expression, as in `amount * 100.0 / SUM(amount) OVER (PARTITION BY region)`; WHERE, GROUP BY and HAVING cannot hold one (filter on a window in an outer query).
- `SELECT *` beside a window lists the table's columns in order, then the window's, and `t.*` lists one table's columns.
- SQL `round(x, 1)` with a digit count is refused (the engine has only one-argument `round`), so the example scales by 1000, rounds, and divides by 10 (komira-ai/komira#2381).
- The pandas-shaped Series has no `round` yet (komira-ai/komira#2381), so the example formats the percent in Python when printing; the stored column keeps full precision.
- Each row stays: `transform("sum")` and the window both put the group total beside every row, unlike `GROUP BY`, which collapses the rows.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I count rows per group?](../35-count-rows-per-group/page.md) (rank 35, works)
- [How do I compute a running total per group?](../48-compute-running-total-per-group/page.md) (rank 48, works)
- [How do I rank rows within a group?](../49-rank-rows-within-group/page.md) (rank 49, works)
