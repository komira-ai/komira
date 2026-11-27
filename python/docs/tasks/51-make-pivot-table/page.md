# How do I make a pivot table?

Sum a column once per value of another column with `CASE WHEN`, grouped by the row key; komira has no `PIVOT` or `pivot_table` yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira
from komira import pl

Path("sales.csv").write_text(
    "region,product,amount\n"
    "east,pen,10\n"
    "east,ink,5\n"
    "west,pen,7\n"
    "west,pen,3\n"
    "north,ink,9\n"
)

# SQL: one conditional sum per new column, one output row per region.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    wide = s.sql(
        "SELECT region,"
        " sum(CASE WHEN product = 'pen' THEN amount ELSE 0 END) AS pen,"
        " sum(CASE WHEN product = 'ink' THEN amount ELSE 0 END) AS ink"
        " FROM sales GROUP BY region ORDER BY region"
    )
    print(wide.to_arrow().to_pylist())

# polars-shaped: the same conditional sums with when/then/otherwise.
pen = pl.when(pl.col("product") == "pen").then(pl.col("amount")).otherwise(0)
ink = pl.when(pl.col("product") == "ink").then(pl.col("amount")).otherwise(0)
wide = (
    pl.scan_csv("sales.csv")
    .group_by("region")
    .agg(pen.sum().alias("pen"), ink.sum().alias("ink"))
    .sort("region")
    .collect()
)
print(wide.to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'pen': Decimal('10'), 'ink': Decimal('5')}, {'region': 'north', 'pen': Decimal('0'), 'ink': Decimal('9')}, {'region': 'west', 'pen': Decimal('10'), 'ink': Decimal('0')}]
[{'region': 'east', 'pen': 10, 'ink': 5}, {'region': 'north', 'pen': 0, 'ink': 9}, {'region': 'west', 'pen': 10, 'ink': 0}]
```

## Notes

- Each `CASE WHEN product = '...'` builds one output column, so the column names are written out in the query; komira does not discover them from the data. A product not listed is left out of the wide table.
- A pair that never occurs sums to 0 because of `ELSE 0`; use `CASE` without `ELSE` for NULL instead.
- In SQL the sum of an integer column comes back as a `Decimal`; the polars-shaped frame returns integers.
- komira has no SQL `PIVOT` yet: `probe_sql_pivot.py` beside this page tries it and must fail with the line in `probe_sql_pivot.error.txt`: komira-ai/komira#2399.
- komira has no pandas-shaped `pivot_table` or `unstack` yet: `probe_pivot_table.py` must fail with the line in `probe_pivot_table.error.txt`: komira-ai/komira#2400. The day either runs, this page's check goes red, and the page and the catalogue status change with it.

## Related

- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- [How do I melt (unpivot) wide data to long?](../52-melt-wide-data-long/page.md) (rank 52, partial)
- [How do I reshape long data to wide?](../53-reshape-long-data-wide/page.md) (rank 53, partial)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
