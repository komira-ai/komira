# How do I rank rows within a group?

In SQL use `RANK()`, `DENSE_RANK()` or `ROW_NUMBER()` with `OVER (PARTITION BY ... ORDER BY ...)`; in the pandas-shaped frame use `groupby(key)[column].rank(method="min")` or `method="dense"`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "rep,region,amount\n"
    "ana,north,100\n"
    "bo,north,100\n"
    "cy,north,70\n"
    "di,south,90\n"
    "ed,south,40\n"
)

# SQL: window functions over a partition. RANK leaves a gap after a tie,
# DENSE_RANK does not, ROW_NUMBER numbers the rows without ties.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    over = "OVER (PARTITION BY region ORDER BY amount DESC"
    sql = (
        "SELECT region, rep, amount,"
        f" RANK() {over}) AS rnk,"
        f" DENSE_RANK() {over}) AS dense,"
        f" ROW_NUMBER() {over}, rep) AS rn"
        " FROM sales ORDER BY region, rn"
    )
    for row in s.sql(sql).to_arrow().to_pylist():
        print(row)

# pandas-shaped: groupby(...).rank, with the tie method named.
df = komira.read_csv("sales.csv")
df["rnk"] = df.groupby("region")["amount"].rank(method="min", ascending=False)
df["dense"] = df.groupby("region")["amount"].rank(method="dense", ascending=False)
out = df.sort_values(["region", "rep"]).materialize().to_arrow()
for row in out.to_pylist():
    print(row)
```

Output:

<!-- include expected_output.txt -->
```text
{'region': 'north', 'rep': 'ana', 'amount': 100, 'rnk': 1, 'dense': 1, 'rn': 1}
{'region': 'north', 'rep': 'bo', 'amount': 100, 'rnk': 1, 'dense': 1, 'rn': 2}
{'region': 'north', 'rep': 'cy', 'amount': 70, 'rnk': 3, 'dense': 2, 'rn': 3}
{'region': 'south', 'rep': 'di', 'amount': 90, 'rnk': 1, 'dense': 1, 'rn': 1}
{'region': 'south', 'rep': 'ed', 'amount': 40, 'rnk': 2, 'dense': 2, 'rn': 2}
{'rep': 'ana', 'region': 'north', 'amount': 100, 'rnk': 1.0, 'dense': 1.0}
{'rep': 'bo', 'region': 'north', 'amount': 100, 'rnk': 1.0, 'dense': 1.0}
{'rep': 'cy', 'region': 'north', 'amount': 70, 'rnk': 3.0, 'dense': 2.0}
{'rep': 'di', 'region': 'south', 'amount': 90, 'rnk': 1.0, 'dense': 1.0}
{'rep': 'ed', 'region': 'south', 'amount': 40, 'rnk': 2.0, 'dense': 2.0}
```

## Notes

- `RANK` gives tied rows the same rank and skips the ranks after them (1, 1, 3); `DENSE_RANK` does not skip (1, 1, 2); `ROW_NUMBER` gives every row its own number, so add a tie-breaker to the `ORDER BY` (here `rep`) to make it deterministic.
- pandas-shaped `rank` returns float64, as pandas does, and `ascending=False` ranks the largest value first. `method="min"` matches SQL `RANK` and `method="dense"` matches `DENSE_RANK`; `na_option` takes `"keep"`, `"top"` and `"bottom"`.
- pandas' default `method="average"` and `method="first"` are refused today, each with an error naming `min` and `dense`; pass the method explicitly. Use SQL `ROW_NUMBER` for the `"first"` behaviour. `rank(pct=True)` is refused too.
- To keep only some ranks, filter with `QUALIFY`, which runs after the window functions (`QUALIFY rank() OVER (...) = 1`, or on the rank's alias), or compute the rank in a subquery and filter it in the outer `WHERE`. `SELECT *` next to a window function works. pandas `groupby(...).cumcount()` is not supported.
- A named window (`OVER w` with a `WINDOW` clause) is refused: write the window inline in each `OVER (...)`.

## Related

- [How do I get the top N rows per group?](../47-get-top-n-rows-per-group/page.md) (rank 47, partial)
- [How do I compute a running total per group?](../48-compute-running-total-per-group/page.md) (rank 48, works)
- [How do I compute each row's percent of its group total?](../50-percent-of-group-total/page.md) (rank 50, partial)
- [How do I count rows per group?](../35-count-rows-per-group/page.md) (rank 35, works)
