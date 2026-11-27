# The form komira does not have yet: parsing text with a format string in SQL,
# with strptime (komira-ai/komira#2366). It must fail with the line of
# probe_strptime.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("id,shipped\n1,09/15/2026\n2,10/20/2026\n")

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    s.sql("SELECT id, strptime(shipped, '%m/%d/%Y') AS shipped FROM orders ORDER BY id")
