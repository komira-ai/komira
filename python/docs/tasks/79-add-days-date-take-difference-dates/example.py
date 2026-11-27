from datetime import timedelta
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
)

# date_diff('day', a, b) is the number of days from a to b, as an integer.
with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    rows = s.sql(
        "SELECT id, order_date, date_diff('day', order_date, ship_date) AS days"
        " FROM orders ORDER BY id"
    ).to_arrow().to_pylist()

# The rows are Python values, so a date plus a timedelta is a date a week on.
for row in rows:
    print(row["id"], row["days"], row["order_date"] + timedelta(days=7))
