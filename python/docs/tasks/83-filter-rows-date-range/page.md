# How do I filter rows by a date range?

Compare the date column with `DATE '...'` literals in `WHERE` (`BETWEEN` keeps both ends; `>=` with `<` leaves the end out), or compare a pandas-shaped column with `datetime.date` values.

<!-- include example.py -->
```python
from datetime import date
from pathlib import Path

import komira

# An ISO date (YYYY-MM-DD) column reads as a DATE.
Path("orders.csv").write_text(
    "id,item,order_date,amount\n"
    "1,pen,2026-09-01,12\n"
    "2,ink,2026-09-03,30\n"
    "3,pad,2026-09-05,25\n"
    "4,pen,2026-09-07,12\n"
    "5,cap,2026-09-10,8\n"
    "6,ink,2026-09-12,30\n"
)

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")

    # BETWEEN keeps both ends.
    both = s.sql(
        "SELECT id, item, order_date FROM orders"
        " WHERE order_date BETWEEN DATE '2026-09-03' AND DATE '2026-09-07'"
        " ORDER BY id"
    )
    for row in both.to_arrow().to_pylist():
        print(row)

    # Half-open: from a date up to, not including, seven days later.
    week = s.sql(
        "SELECT id FROM orders"
        " WHERE order_date >= DATE '2026-09-05'"
        " AND order_date < DATE '2026-09-05' + INTERVAL '7' DAY"
        " ORDER BY id"
    )
    print([row["id"] for row in week.to_arrow().to_pylist()])

# pandas-shaped: compare the column with datetime.date values.
df = komira.read_csv("orders.csv")
print(df.dtypes["order_date"])
window = df[(df["order_date"] >= date(2026, 9, 3)) & (df["order_date"] < date(2026, 9, 10))]
print(window[["id", "item"]].sort_values("id").materialize().to_arrow().to_pylist())
```

Output:

<!-- include expected_output.txt -->
```text
{'id': 2, 'item': 'ink', 'order_date': datetime.date(2026, 9, 3)}
{'id': 3, 'item': 'pad', 'order_date': datetime.date(2026, 9, 5)}
{'id': 4, 'item': 'pen', 'order_date': datetime.date(2026, 9, 7)}
[3, 4, 5]
date32
[{'id': 2, 'item': 'ink'}, {'id': 3, 'item': 'pad'}, {'id': 4, 'item': 'pen'}]
```

## Notes

- A CSV column whose every value is `YYYY-MM-DD` reads as a DATE (`date32`), and comes back to Python as `datetime.date`.
- `BETWEEN a AND b` means `>= a AND <= b`, so both ends are kept. The half-open form `>= start AND < next_start` has no end to get wrong when a range runs to the end of a day or a month.
- `DATE '...' + INTERVAL '7' DAY` is worked out when the query is prepared, so the date it starts from is a literal, as in the example.
- The pandas-shaped frame has no `Series.between` today: write the two comparisons joined with `&`, each side in parentheses.
- Rows come back in no promised order unless the query sorts them: add `ORDER BY` or `sort_values`.

## Related

- How do I select columns and filter rows? (rank 2, works)
- How do I extract year, month and weekday from a date column? (rank 39, works; no page yet)
- How do I add days to a date or take the difference between dates? (rank 79, partial; no page yet)
- How do I group by month or week? (rank 80, works; no page yet)
