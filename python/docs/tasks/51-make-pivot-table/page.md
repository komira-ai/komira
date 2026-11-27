# How do I make a pivot table?

In SQL, `PIVOT (sum(amount) FOR product IN ('pen', 'ink'))` makes one column per listed value and one row per value of the other columns; a `CASE WHEN` per column does the same by hand. komira has no pandas-shaped `pivot_table` yet.

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

# SQL PIVOT: one column per listed product, one output row per region.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    wide = s.sql(
        "SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))"
        " ORDER BY region"
    )
    print(wide.to_arrow().to_pylist())

    # The same table with one conditional sum per new column; ELSE 0 turns
    # a missing pair into 0.
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
[{'region': 'east', 'pen': Decimal('10'), 'ink': Decimal('5')}, {'region': 'north', 'pen': None, 'ink': Decimal('9')}, {'region': 'west', 'pen': Decimal('10'), 'ink': None}]
[{'region': 'east', 'pen': Decimal('10'), 'ink': Decimal('5')}, {'region': 'north', 'pen': Decimal('0'), 'ink': Decimal('9')}, {'region': 'west', 'pen': Decimal('10'), 'ink': Decimal('0')}]
[{'region': 'east', 'pen': 10, 'ink': 5}, {'region': 'north', 'pen': 0, 'ink': 9}, {'region': 'west', 'pen': 10, 'ink': 0}]
```

## Notes

- `PIVOT` groups by every column it does not name: here `region`, since `product` is the FOR column and `amount` is inside the aggregate. Select the columns you want in a derived table first (`FROM (SELECT ...) PIVOT (...)`) to group by fewer.
- The new columns are the values listed after `IN`, named by them (`'pen' AS p` renames one); komira does not discover them from the data, so the statement form `PIVOT sales ON product USING sum(amount)` is refused. A product not listed adds no column, and its rows still form their group.
- A pair that never occurs is NULL with `PIVOT` (`north` has no `pen`), and 0 with the `CASE WHEN ... ELSE 0` form; `count` gives 0 in both.
- The value pivoted must be a BIGINT or a DOUBLE, or be counted: `PIVOT (max(name) ...)` over a text column is refused by name, since the empty cell would be a text NULL, which komira's plans cannot carry yet.
- In SQL the sum of an integer column comes back as a `Decimal`; the polars-shaped frame returns integers.
- komira has no pandas-shaped `pivot_table` or `unstack` yet: `probe_pivot_table.py` must fail with the line in `probe_pivot_table.error.txt`: komira-ai/komira#2400. The day it runs, this page's check goes red, and the page and the catalogue status change with it.

## Related

- [How do I cross-tabulate two columns?](../54-cross-tabulate-two-columns/page.md) (rank 54, partial)
- [How do I melt (unpivot) wide data to long?](../52-melt-wide-data-long/page.md) (rank 52, partial)
- [How do I reshape long data to wide?](../53-reshape-long-data-wide/page.md) (rank 53, partial)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
