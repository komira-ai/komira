# The form komira does not have yet: sort the months with ORDER BY on the
# date (komira-ai/komira#2408). It must fail with the line of
# probe_order_by_date.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("order_id,order_date\n1,2024-01-03\n2,2024-02-05\n")

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    s.sql(
        "SELECT date_trunc('month', order_date) AS month_start, count(*) AS n"
        " FROM orders GROUP BY 1 ORDER BY month_start"
    ).to_arrow()
