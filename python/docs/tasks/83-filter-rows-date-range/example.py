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
