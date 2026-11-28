# How do I get the top N rows per group?

Number the rows in each group with `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)` in a subquery and keep the first N, or on the pandas-shaped frame rank within each group and keep the rows ranked N or better.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "region,rep,amount\n"
    "east,Ana,120\n"
    "east,Bo,80\n"
    "east,Cy,200\n"
    "east,Di,150\n"
    "west,Ed,90\n"
    "west,Flo,60\n"
    "west,Gus,300\n"
    "north,Hal,50\n"
)

# SQL: number the rows in each group with ROW_NUMBER, then keep numbers up to 2.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    top2 = s.sql(
        "SELECT region, rep, amount FROM ("
        " SELECT region, rep, amount,"
        " ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn"
        " FROM sales) ranked"
        " WHERE rn <= 2 ORDER BY region, amount DESC"
    )
    print(top2.to_arrow().to_pylist())

# pandas-shaped: rank within each group, keep the rows ranked 2 or better.
df = komira.read_csv("sales.csv")
rank = df.groupby("region")["amount"].rank(method="min", ascending=False)
top2 = df[rank <= 2].sort_values(["region", "amount"], ascending=[True, False])
print(top2.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'rep': 'Cy', 'amount': 200}, {'region': 'east', 'rep': 'Di', 'amount': 150}, {'region': 'north', 'rep': 'Hal', 'amount': 50}, {'region': 'west', 'rep': 'Gus', 'amount': 300}, {'region': 'west', 'rep': 'Ed', 'amount': 90}]
[{'region': 'east', 'rep': 'Cy', 'amount': 200}, {'region': 'east', 'rep': 'Di', 'amount': 150}, {'region': 'north', 'rep': 'Hal', 'amount': 50}, {'region': 'west', 'rep': 'Gus', 'amount': 300}, {'region': 'west', 'rep': 'Ed', 'amount': 90}]
```

## Notes

- `rn <= 2` and `rn < 3` keep the first two rows of each group, and `rn BETWEEN 1 AND 2`, `rn IN (1, 2)` give the same rows. Rows tied on every `ORDER BY` key are numbered in no promised order, in DuckDB too: add a key that tells them apart (`ORDER BY amount DESC, rep`) when the cut can fall inside a tie. `RANK() OVER (...) AS rk` with `rk <= 2` keeps every row tied within the first two places, as DuckDB does, so a tie at the cut keeps more than two rows. A NULL in the `PARTITION BY` column forms one group of its own, and NULLs in the `ORDER BY` column come last in both directions.
- `QUALIFY` is refused by name; the message points to this subquery form.
- The subquery needs an alias (`ranked` above), and `SELECT *` next to a window function in the same select list is refused, so name the columns.
- On the pandas-shaped frame, `groupby("region")["amount"].rank(method="min", ascending=False)` ranks each row within its group. `method="min"` gives tied rows the same rank, so a tie at the cut keeps more than N rows; `method="first"` is refused because a frame has no row order. `groupby().head(n)`, `groupby().cumcount()`, `groupby().nlargest(n)` and `DataFrame.nlargest` are not there: pandas' `head` keeps each group's first rows in the frame's row order and index, and `nlargest(keep="first")` breaks ties by that order, and a frame has neither (komira-ai/komira#2377).
- Rows come back in no promised order unless sorted: add `ORDER BY` or `sort_values`.
- For the single top row per group, write `rn = 1` or `rn <= 1`, or take the group's `max` and join it back.

## Related

- How do I remove duplicate rows? (rank 13, works; no page yet)
- [How do I compute a running total per group?](../48-compute-running-total-per-group/page.md) (rank 48, works)
- [How do I rank rows within a group?](../49-rank-rows-within-group/page.md) (rank 49, works)
