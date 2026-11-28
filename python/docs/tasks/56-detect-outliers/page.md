# How do I detect outliers?

Flag the values far from the mean in SQL with a z-score, or outside the quartile fences with the interquartile-range rule, whose quartiles come from `Series.quantile`.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Ten order totals; two of them are far from the rest.
totals = [10, 12, 11, 13, 12, 11, 10, 95, 12, -40]
Path("orders.csv").write_text(
    "id,total\n" + "".join(f"{i},{t}\n" for i, t in enumerate(totals, 1))
)

# A z-score rule: flag a value more than 1.5 standard deviations from the mean.
# stddev_pop is the population standard deviation.
query = """
WITH stats AS (
    SELECT avg(total) AS mean, stddev_pop(total) AS sd
    FROM orders
)
SELECT id, total, (total - mean) / sd AS z
FROM orders, stats
WHERE abs(total - mean) > 1.5 * sd
ORDER BY id
"""

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    for row in s.sql(query).to_arrow().to_pylist():
        print(f"id={row['id']} total={row['total']} z={row['z']:.2f}")

# The interquartile-range rule: flag a value below Q1 - 1.5 * IQR or above
# Q3 + 1.5 * IQR. Series.quantile runs at once and gives a float.
df = komira.read_csv("orders.csv")
q1, q3 = df["total"].quantile(0.25), df["total"].quantile(0.75)
iqr = q3 - q1
low, high = q1 - 1.5 * iqr, q3 + 1.5 * iqr
print(f"q1={q1} q3={q3} iqr={iqr} fences=({low}, {high})")
outliers = df[(df["total"] < low) | (df["total"] > high)].sort_values("id")
for row in outliers.materialize().to_arrow().to_pylist():
    print(f"id={row['id']} total={row['total']}")
```

Output:

<!-- include expected_output.txt -->
```text
id=8 total=95 z=2.60
id=10 total=-40 z=-1.77
q1=10.25 q3=12.0 iqr=1.75 fences=(7.625, 14.625)
id=8 total=95
id=10 total=-40
```

## Notes

- The z-score query joins each row to one row of statistics (`avg` and `stddev_pop`) and keeps the rows more than 1.5 standard deviations from the mean. The sample is small, so the cut-off is 1.5; a common choice on larger data is 3. `stddev_pop` is the population standard deviation; `stddev_samp` (also `stddev`) is the sample one.
- The interquartile-range rule takes the quartiles with `df["total"].quantile(0.25)` and `quantile(0.75)`: pandas' linear interpolation, which is SQL's `quantile_cont`. Each call runs a query at once and gives a Python float (NaN for a column with no values), so the fences are plain numbers that the filter then uses. The same quartiles in SQL are `quantile_cont(total, 0.25)` and `quantile_cont(total, 0.75)`.
- `Series.quantile` takes one fraction from 0 to 1 and `interpolation="linear"`; a list of fractions and another interpolation are refused by name.
- The mean is itself pulled by the outliers, so a large outlier can hide a smaller one; the quartiles are not, so the interquartile-range rule is the steadier of the two. Either is a first look, not a verdict.
- The frame's `df.mean()`, `df.std()` and `df.median()` give one row each, as in the page on summary statistics.

## Related

- [How do I compute summary statistics of a column?](../24-compute-summary-statistics-column/page.md) (rank 24, partial)
- [How do I find (not drop) duplicate rows?](../57-find-duplicate-rows/page.md) (rank 57, works)
- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)
