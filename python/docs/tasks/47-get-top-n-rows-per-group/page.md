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

# SQL: number the rows in each group with ROW_NUMBER, then keep numbers 1 to 2.
# BETWEEN 1 AND 2 stands where most people write rn <= 2 (see the notes).
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    top2 = s.sql(
        "SELECT region, rep, amount FROM ("
        " SELECT region, rep, amount,"
        " ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn"
        " FROM sales) ranked"
        " WHERE rn BETWEEN 1 AND 2 ORDER BY region, amount DESC"
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

- Write the filter as `rn BETWEEN 1 AND 2` (or `rn IN (1, 2)`), not `rn <= 2`. The plain `rn <= N` form, the one most people write, fails today with `UnsupportedOperation: lower: LOWERING_UNCUTTABLE_NODE: PartitionTopN (no cutter arm for this node) is not cut`, because the optimizer turns that exact shape into a node komira cannot run yet (komira-ai/komira#2377). `probe_rn_at_most.py` beside this page tries it and must fail with the line in `probe_rn_at_most.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- `QUALIFY` filters on the window's result without the subquery: `SELECT region, rep, amount FROM sales QUALIFY row_number() OVER (PARTITION BY region ORDER BY amount DESC) BETWEEN 1 AND 2`. Write its bound as `BETWEEN` too: `<= N` fails there the same way.
- The subquery needs an alias (`ranked` above). `SELECT *` next to a window function works.
- On the pandas-shaped frame, `groupby("region")["amount"].rank(method="min", ascending=False)` ranks each row within its group. `method="min"` gives tied rows the same rank, so a tie at the cut keeps more than N rows; `method="first"` is refused because a frame has no row order. `groupby().head(n)`, `groupby().cumcount()`, `groupby().nlargest(n)` and `DataFrame.nlargest` are not there.
- Rows come back in no promised order unless sorted: add `ORDER BY` or `sort_values`.
- For the single top row per group, `rn = 1` runs as written, or take the group's `max` and join it back.

## Related

- How do I remove duplicate rows? (rank 13, works; no page yet)
- [How do I compute a running total per group?](../48-compute-running-total-per-group/page.md) (rank 48, works)
- [How do I rank rows within a group?](../49-rank-rows-within-group/page.md) (rank 49, works)
