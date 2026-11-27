# How do I compute several aggregates at once with named outputs?

List the aggregates in one `SELECT` and name each with `AS`, or call `agg(name=("column", "function"))` on a pandas-shaped frame, grouped or not.

<!-- include example.py -->
```python
from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
    "6,Cy,north,60\n"
)

# SQL: every aggregate is a select item, and AS names its output column.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    total = s.sql(
        "SELECT count(*) AS orders, sum(amount) AS revenue,"
        " min(amount) AS smallest, max(amount) AS largest,"
        " count(DISTINCT customer) AS customers FROM orders"
    )
    print(total.to_arrow().to_pylist())

    # The same per group: the key columns, then the named aggregates.
    by_region = s.sql(
        "SELECT region, count(*) AS orders, sum(amount) AS revenue, max(amount) AS largest"
        " FROM orders GROUP BY region ORDER BY region"
    )
    print(by_region.to_arrow().to_pylist())

# pandas-shaped: agg(name=("column", "function")) names each output.
df = komira.read_csv("orders.csv")
stats = df.groupby("region").agg(
    orders=("order_id", "count"),
    revenue=("amount", "sum"),
    largest=("amount", "max"),
)
print(stats.sort_values("region").materialize().to_arrow().to_pylist())

# Without groupby, agg reduces the whole frame to one row.
print(df.agg(revenue=("amount", "sum"), largest=("amount", "max")).materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'orders': 6, 'revenue': Decimal('655'), 'smallest': 45, 'largest': 200, 'customers': 3}]
[{'region': 'east', 'orders': 2, 'revenue': Decimal('165'), 'largest': 120}, {'region': 'north', 'orders': 2, 'revenue': Decimal('260'), 'largest': 200}, {'region': 'west', 'orders': 2, 'revenue': Decimal('230'), 'largest': 150}]
[{'region': 'east', 'orders': 2, 'revenue': 165, 'largest': 120}, {'region': 'north', 'orders': 2, 'revenue': 260, 'largest': 200}, {'region': 'west', 'orders': 2, 'revenue': 230, 'largest': 150}]
[{'revenue': 655, 'largest': 200}]
```

## Notes

- In SQL, `count(*)`, `sum`, `min`, `max`, `avg` and `count(DISTINCT ...)` can sit side by side in one `SELECT`; add `GROUP BY` for one row per group.
- `sum` of an integer column comes back as a decimal in SQL (`Decimal('655')`) and as an integer on the pandas-shaped frame. `CAST(sum(x) AS BIGINT)` is refused today: a function wrapping an aggregate is not lowered yet.
- On the frame the output name is the keyword and the pair is `("column", "function")`, with the function a name such as `"sum"`, `"count"`, `"min"`, `"max"` or `"mean"`. `NamedAgg` is refused: use the tuple.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I compute summary statistics of a column?](../24-compute-summary-statistics-column/page.md) (rank 24, partial)
- How do I group by a column and sum another column? (rank 4, works; no page yet)
- How do I count rows per group? (rank 35, works; no page yet)
