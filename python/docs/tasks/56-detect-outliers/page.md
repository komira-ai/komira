# How do I detect outliers?

Flag the values far from the mean in SQL with a z-score; komira cannot yet compute the quartiles the interquartile-range rule needs.

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
# The standard deviation is written as sqrt(avg(x*x) - avg(x)^2), the population form.
query = """
WITH stats AS (
    SELECT avg(total) AS mean,
           sqrt(avg(total * total) - avg(total) * avg(total)) AS sd
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
```

Output:

<!-- include expected_output.txt -->
```text
id=8 total=95 z=2.60
id=10 total=-40 z=-1.77
```

## Notes

- The query joins each row to one row of statistics (`avg` and a standard deviation) and keeps the rows more than 1.5 standard deviations from the mean. The sample is small, so the cut-off is 1.5; a common choice on larger data is 3.
- The standard deviation is written as `sqrt(avg(x * x) - avg(x) * avg(x))`, which is the population standard deviation. komira does not run `stddev`, `stddev_pop`, `var_pop` or `median` as aggregates yet, and refuses `quantile_cont`: komira-ai/komira#2367.
- Without quartiles the interquartile-range rule (below Q1 - 1.5 * IQR or above Q3 + 1.5 * IQR) cannot be written. `probe_quantile.py` beside this page tries it with the pandas-shaped `Series.quantile` and must fail with the line in `probe_quantile.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it.
- The mean is itself pulled by the outliers, so a large outlier can hide a smaller one; the rule here is a first look, not a verdict.
- The pandas-shaped frame has `df.mean()`, but `df.std()` and `df.median()` fail at execute with the same aggregate refusal as SQL, and a column (`df["total"]`) has no `mean()`, `std()` or `quantile()`; so the statistics come from SQL.

## Related

- How do I compute summary statistics of a column? (rank 24, works; no page yet)
- [How do I find (not drop) duplicate rows?](../57-find-duplicate-rows/page.md) (rank 57, works)
- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- [How do I validate data: nulls, uniqueness, ranges?](../59-validate-data-nulls-uniqueness-ranges/page.md) (rank 59, works)
