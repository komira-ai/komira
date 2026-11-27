# The form most people write: the window SUM inside the division, one SELECT.
# komira refuses a window function nested in an expression.
# It must fail with the line of probe_window_in_expression.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("region,amount\neast,120\neast,80\n")

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.sql("SELECT amount * 100.0 / SUM(amount) OVER (PARTITION BY region) AS pct FROM sales")
