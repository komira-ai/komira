# How do I compare each row with the previous row (lag, lead, change)?

Use the SQL window functions `lag` and `lead`, and take the change as `x - prev` over them in an outer query; the pandas-shaped `shift()` and `diff()` are not available yet.

<!-- include example.py -->
```python
from pathlib import Path

import komira

# Daily sales, one row per step t.
Path("sales.csv").write_text("t,sales\n1,10\n2,13\n3,13\n4,9\n")

# lag looks at the previous row in the window's order, lead at the next
# one; both read NULL where there is no such row. The change from the
# previous row is the value minus its lag, taken in an outer query.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    for row in s.sql(
        "SELECT t, sales, prev, nxt, sales - prev AS change FROM ("
        "  SELECT t, sales,"
        "  lag(sales) OVER (ORDER BY t) AS prev,"
        "  lead(sales) OVER (ORDER BY t) AS nxt"
        "  FROM sales"
        ") ORDER BY t"
    ).to_arrow().to_pylist():
        print(row)
```

Output:

<!-- include expected_output.txt -->
```text
{'t': 1, 'sales': 10, 'prev': None, 'nxt': 13, 'change': None}
{'t': 2, 'sales': 13, 'prev': 10, 'nxt': 13, 'change': 3}
{'t': 3, 'sales': 13, 'prev': 13, 'nxt': 9, 'change': 0}
{'t': 4, 'sales': 9, 'prev': 13, 'nxt': None, 'change': -4}
```

## Notes

- `lag(x)` is the value of `x` one row back in the window's order, and `lead(x)` one row ahead; `lag(x, 2)` goes two rows back, and `lag(x, 1, 0)` reads 0 instead of NULL where there is no such row.
- The order is the one in `OVER (ORDER BY ...)`; add `PARTITION BY k` to compare within each group, so the first row of every group has no previous row.
- A row with no previous (or next) row reads NULL, and so does its change.
- A window function must be a whole item of the `SELECT` list today: `sales - lag(sales) OVER (ORDER BY t)` in one item is refused by name, so the example takes the difference in an outer query (komira-ai/komira#2379).
- The pandas-shaped frame (`komira.read_csv`) and `komira.pl` have no `shift()` or `diff()` yet (komira-ai/komira#2387): `df.shift(1)` raises `AttributeError: .shift() is not supported yet`. `probe_shift.py` beside this page tries it and must fail with the line in `probe_shift.error.txt`. The day it runs, this page's check goes red, and the page and the catalogue status change with it. Until then, write the comparison in SQL as above.

## Related

- How do I compute a rolling average? (rank 76, works)
- How do I add days to a date or take the difference between dates? (rank 79, works)
