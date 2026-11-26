# How do I select columns and filter rows?

Name the columns in `SELECT` and the condition in `WHERE`, or index a pandas-shaped frame with a boolean Series and then a list of column names.

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
)

# SQL: the columns you want in SELECT, the condition in WHERE.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    big = s.sql(
        "SELECT order_id, customer, amount FROM orders"
        " WHERE amount > 100 ORDER BY order_id"
    )
    print(big.to_arrow().to_pylist())

    # Several conditions, and a list of allowed values.
    east_or_north = s.sql(
        "SELECT order_id, region FROM orders"
        " WHERE amount >= 45 AND region IN ('east', 'north') ORDER BY order_id"
    )
    print(east_or_north.to_arrow().to_pylist())

# pandas-shaped: a boolean Series picks rows, a list of names picks columns.
df = komira.read_csv("orders.csv")
big = df[df["amount"] > 100][["order_id", "customer", "amount"]]
print(big.sort_values("order_id").materialize().to_arrow().to_pylist())

west_big = df[(df["region"] == "west") & (df["amount"] > 100)][["order_id"]]
print(west_big.materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 4, 'customer': 'Cy', 'amount': 200}, {'order_id': 5, 'customer': 'Bo', 'amount': 150}]
[{'order_id': 1, 'region': 'east'}, {'order_id': 3, 'region': 'east'}, {'order_id': 4, 'region': 'north'}]
[{'order_id': 1, 'customer': 'Ana', 'amount': 120}, {'order_id': 4, 'customer': 'Cy', 'amount': 200}, {'order_id': 5, 'customer': 'Bo', 'amount': 150}]
[{'order_id': 5}]
```

## Notes

- Combine conditions with `AND` / `OR` in SQL, and with `&` / `|` (each side in parentheses) on the pandas-shaped frame.
- `IN (...)` in SQL and `Series.isin([...])` keep rows whose value is in a list.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- How do I filter rows where a value is in a list? (rank 29, works; no page yet)
- How do I select or drop columns? (rank 34, works; no page yet)
- How do I filter rows where a text column contains a substring? (rank 41, works; no page yet)
- How do I filter rows by a date range? (rank 83, works)
