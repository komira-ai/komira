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
