from pathlib import Path

import komira

# Orders with the day each was placed and the day it shipped. A column of
# YYYY-MM-DD values is read as a date.
Path("orders.csv").write_text(
    "id,order_date,ship_date\n"
    "1,2024-01-30,2024-02-02\n"
    "2,2024-02-27,2024-03-01\n"
    "3,2024-03-05,2024-03-05\n"
    "4,2023-12-30,2024-01-03\n"
    "5,2024-01-31,2024-02-20\n"
)

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")

    # date_diff('day', a, b) is the number of days from a to b, as an integer.
    # A date plus an INTERVAL is a timestamp at midnight, as in DuckDB; a
    # date plus a whole number of days is a date. A month is added by calendar
    # month, and a day that the month does not have becomes its last day.
    rows = s.sql(
        "SELECT id,"
        " date_diff('day', order_date, ship_date) AS days,"
        " order_date + INTERVAL '7' DAY AS week_on,"
        " order_date + INTERVAL '1' MONTH AS month_on,"
        " order_date + 7 AS seven_days_on"
        " FROM orders ORDER BY id"
    ).to_arrow().to_pylist()

    # A shifted date compares with another date column: the orders that
    # shipped more than a week after they were placed.
    late = s.sql(
        "SELECT id FROM orders"
        " WHERE ship_date > order_date + INTERVAL '7' DAY ORDER BY id"
    ).to_arrow().to_pylist()

for row in rows:
    print(row["id"], row["days"], row["week_on"], row["month_on"], row["seven_days_on"])
print("late:", [row["id"] for row in late])
