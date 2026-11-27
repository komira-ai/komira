# The form komira does not have yet: add an INTERVAL to a date column in SQL
# (komira-ai/komira#2388). It must fail with the line of
# probe_column_plus_interval.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("id,order_date,ship_date\n1,2024-01-30,2024-02-12\n")

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    s.sql("SELECT id FROM orders WHERE ship_date > order_date + INTERVAL '7' DAY")
