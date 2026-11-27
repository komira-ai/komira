# How do I join on multiple columns?

Name every key: `ON a.x = b.x AND a.y = b.y` (or `USING (x, y)`) in SQL, `merge(on=["x", "y"])` on the pandas-shaped frame, `join(on=["x", "y"])` on the polars-shaped one.

<!-- include example.py -->
```python
from pathlib import Path

import komira
import komira.pl as pl

Path("sales.csv").write_text(
    "region,product,units\n"
    "east,apple,10\n"
    "east,pear,5\n"
    "west,apple,7\n"
    "west,pear,3\n"
)
Path("prices.csv").write_text(
    "region,product,price\n"
    "east,apple,2\n"
    "east,pear,4\n"
    "west,apple,3\n"
    "north,apple,9\n"
)

# SQL: put every key in ON, joined with AND.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.register_csv("prices", "prices.csv")
    on = s.sql(
        "SELECT s.region, s.product, s.units, p.price FROM sales s"
        " JOIN prices p ON s.region = p.region AND s.product = p.product"
        " ORDER BY s.region, s.product"
    )
    print(on.to_arrow().to_pylist())

    # Keys spelled alike on both sides can go in USING, which keeps one copy.
    using = s.sql(
        "SELECT region, product, units, price FROM sales"
        " JOIN prices USING (region, product) ORDER BY region, product"
    )
    print(using.to_arrow().to_pylist())

# pandas-shaped: merge(on=[...]).
sales = komira.read_csv("sales.csv")
prices = komira.read_csv("prices.csv")
merged = sales.merge(prices, on=["region", "product"])
print(merged.sort_values(["region", "product"]).materialize().to_arrow().to_pylist())

# polars-shaped: join(on=[...]).
joined = pl.scan_csv("sales.csv").join(pl.scan_csv("prices.csv"), on=["region", "product"])
print(joined.sort("region", "product").collect().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
[{'region': 'east', 'product': 'apple', 'units': 10, 'price': 2}, {'region': 'east', 'product': 'pear', 'units': 5, 'price': 4}, {'region': 'west', 'product': 'apple', 'units': 7, 'price': 3}]
[{'region': 'east', 'product': 'apple', 'units': 10, 'price': 2}, {'region': 'east', 'product': 'pear', 'units': 5, 'price': 4}, {'region': 'west', 'product': 'apple', 'units': 7, 'price': 3}]
[{'region': 'east', 'product': 'apple', 'units': 10, 'price': 2}, {'region': 'east', 'product': 'pear', 'units': 5, 'price': 4}, {'region': 'west', 'product': 'apple', 'units': 7, 'price': 3}]
[{'region': 'east', 'product': 'apple', 'units': 10, 'price': 2}, {'region': 'east', 'product': 'pear', 'units': 5, 'price': 4}, {'region': 'west', 'product': 'apple', 'units': 7, 'price': 3}]
```

## Notes

- A row joins only when every key matches: `west` / `pear` has no price and `north` / `apple` has no sale, so neither is in the answer. Joining on `region` alone would pair every `east` sale with every `east` price.
- All four forms answer the same rows with the columns `region`, `product`, `units`, `price`: a key named alike on both sides appears once in `USING`, `merge` and `join`, while the SQL `ON` form lists the columns you choose.
- A row whose key is NULL matches nothing, as in SQL; unlike pandas, `merge` does not pair NULL keys with each other.
- `USING` works for inner and left joins; for a right or full join write the keys in `ON`.
- A join returns rows in no promised order: add `ORDER BY`, `sort_values` or `sort`.
- Keys with different names: `merge(left_on=[...], right_on=[...])` and `join(left_on=[...], right_on=[...])`, or the two names in `ON`.

## Related

- How do I join two tables on a key? (rank 10, works; no page yet)
- How do I left join and keep unmatched rows? (rank 36, works; no page yet)
- How do I cross join two tables? (rank 71, works)
- How do I join many tables in one query? (rank 74, works)
- How do I join where a value falls between two bounds? (rank 75, works)
