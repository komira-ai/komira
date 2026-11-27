from pathlib import Path

import komira

Path("orders.csv").write_text(
    "order_id,order_date,amount\n"
    "1,2024-01-03,10\n"
    "2,2024-01-15,20\n"
    "3,2024-01-16,5\n"
    "4,2024-02-05,40\n"
    "5,2024-02-07,15\n"
    "6,2024-02-29,30\n"
)

# SQL: date_trunc cuts a date down to the first day of its month or week.
# ORDER BY a date column is not supported yet, so the rows are sorted in
# Python.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    by_month = s.sql(
        "SELECT date_trunc('month', order_date) AS month_start, count(*) AS n"
        " FROM orders GROUP BY 1"
    )
    print(sorted(by_month.to_arrow().to_pylist(), key=lambda r: r["month_start"]))

    # Weeks start on Monday.
    by_week = s.sql(
        "SELECT date_trunc('week', order_date) AS week_start, count(*) AS n"
        " FROM orders GROUP BY 1"
    )
    print(sorted(by_week.to_arrow().to_pylist(), key=lambda r: r["week_start"]))

# pandas-shaped: add the year and the month as columns, then group by them.
df = komira.read_csv("orders.csv")
df = df.assign(year=df["order_date"].dt.year, month=df["order_date"].dt.month)
print(df.groupby(["year", "month"]).size().materialize().to_arrow().to_pylist())
