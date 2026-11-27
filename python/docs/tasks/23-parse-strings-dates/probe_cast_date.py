# The form komira does not have yet: parsing text into a date in SQL, with
# CAST(<text> AS DATE) (komira-ai/komira#2366). It must fail with the line
# of probe_cast_date.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("id,shipped\n1,15 Sep 2026\n2,01 Oct 2026\n")

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    s.sql("SELECT id, CAST(shipped AS DATE) AS shipped FROM orders ORDER BY id")
