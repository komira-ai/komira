# How do I count rows per group?

Use `count(*)` with `GROUP BY` in SQL, `df.groupby(keys).size()` on a pandas-shaped frame, or `group_by(keys).len()` on a polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as kpl

Path("orders.csv").write_text(
    "order_id,customer,region,amount\n"
    "1,Ana,east,120\n"
    "2,Bo,west,80\n"
    "3,Ana,east,45\n"
    "4,Cy,north,200\n"
    "5,Bo,west,150\n"
)

# SQL: count(*) per GROUP BY key.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    per_region = s.sql(
        "SELECT region, count(*) AS orders FROM orders"
        " GROUP BY region ORDER BY orders DESC, region"
    )
    print(per_region.to_arrow().to_pylist())

# pandas-shaped: groupby(...).size() has the keys and a column named size.
df = komira.read_csv("orders.csv")
print(df.groupby("region").size().materialize().to_arrow().to_pylist())

busiest = df.groupby("region").size().sort_values(["size", "region"], ascending=[False, True])
print(busiest.head(2).materialize().to_arrow().to_pylist())

# Two keys: one row per pair that occurs.
pairs = df.groupby(["region", "customer"]).size()
print(pairs.materialize().to_arrow().to_pylist())

# polars-shaped: group_by(...).len() has the keys and a column named len.
lf = kpl.scan_csv("orders.csv")
print(lf.group_by("region").len().sort("region").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'orders': 2}, {'region': 'west', 'orders': 2}, {'region': 'north', 'orders': 1}]
[{'region': 'east', 'size': 2}, {'region': 'north', 'size': 1}, {'region': 'west', 'size': 2}]
[{'region': 'east', 'size': 2}, {'region': 'west', 'size': 2}]
[{'region': 'east', 'customer': 'Ana', 'size': 2}, {'region': 'north', 'customer': 'Cy', 'size': 1}, {'region': 'west', 'customer': 'Bo', 'size': 2}]
[{'region': 'east', 'len': 2}, {'region': 'north', 'len': 1}, {'region': 'west', 'len': 2}]
```

## Notes

- `groupby(...).size()` counts rows and names its column `size`; the polars-shaped `len()` names its column `len` (pass a name to change it). In SQL the name is the alias you give.
- `groupby(...).count()` is different: it counts the values that are not missing, per column. `size()` and `count(*)` count rows.
- `groupby` sorts by its keys, as pandas does; add `sort_values` to rank groups by their count. The polars-shaped frame and SQL return no promised order, so sort them.
- pandas' `Series.value_counts()` is refused by name; `df.groupby(column).size()` with `sort_values("size", ascending=False)` is the spelling its message gives.

## Related

- How do I group by a column and sum another column? (rank 4, works; no page yet)
- How do I count how many times each value appears? (rank 9, works; no page yet)
