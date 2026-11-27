# How do I filter rows where a value is in a list?

Use `WHERE col IN (...)` in SQL, or `df[df["col"].isin([...])]` on a pandas-shaped frame; negate with `NOT IN` or `~`.

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
    "6,Cy,south,60\n"
)
wanted = ["east", "north"]

# SQL: IN keeps the rows whose value is in the list, NOT IN the others.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    kept = s.sql("SELECT order_id, region FROM orders WHERE region IN ('east', 'north') ORDER BY order_id")
    print(kept.to_arrow().to_pylist())
    rest = s.sql("SELECT order_id, region FROM orders WHERE region NOT IN ('east', 'north') ORDER BY order_id")
    print(rest.to_arrow().to_pylist())

# pandas-shaped: isin takes a Python list; ~ negates it.
df = komira.read_csv("orders.csv")
kept = df[df["region"].isin(wanted)].sort_values("order_id")
print(kept.materialize().to_arrow().to_pylist())
rest = df[~df["region"].isin(wanted)].sort_values("order_id")
print(rest.materialize().to_arrow().to_pylist())

# Numbers work the same way.
ids = df[df["order_id"].isin([2, 4, 6])][["order_id", "customer"]].sort_values("order_id")
print(ids.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'order_id': 1, 'region': 'east'}, {'order_id': 3, 'region': 'east'}, {'order_id': 4, 'region': 'north'}]
[{'order_id': 2, 'region': 'west'}, {'order_id': 5, 'region': 'west'}, {'order_id': 6, 'region': 'south'}]
[{'order_id': 1, 'customer': 'Ana', 'region': 'east', 'amount': 120}, {'order_id': 3, 'customer': 'Ana', 'region': 'east', 'amount': 45}, {'order_id': 4, 'customer': 'Cy', 'region': 'north', 'amount': 200}]
[{'order_id': 2, 'customer': 'Bo', 'region': 'west', 'amount': 80}, {'order_id': 5, 'customer': 'Bo', 'region': 'west', 'amount': 150}, {'order_id': 6, 'customer': 'Cy', 'region': 'south', 'amount': 60}]
[{'order_id': 2, 'customer': 'Bo'}, {'order_id': 4, 'customer': 'Cy'}, {'order_id': 6, 'customer': 'Cy'}]
```

## Notes

- `IN (...)` and `isin` keep the rows whose value equals one of the list; `NOT IN` and `~isin` keep the others.
- `isin` takes a Python list or tuple of at most 64 values. For a longer list, put the values in a table and filter with a join.
- `isin` also takes a column of another frame of the same session, which keeps the rows with a matching key (a semi join); that form is newer than release 0.1.1623.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- [How do I select columns and filter rows?](../2-select-columns-filter-rows/page.md) (rank 2, works)
- How do I filter rows where a text column contains a substring? (rank 41, works; no page yet)
- How do I filter rows by a date range? (rank 83, works; no page yet)
