# The DuckDB spelling komira does not parse yet: SELECT * EXCLUDE (...).
# Name the columns to keep instead (see the page).
# It must fail with the line of probe_sql_exclude.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("order_id,customer,note\n1,Ana,gift\n")

with komira.Session() as s:
    s.register_csv("orders", "orders.csv")
    s.sql("SELECT * EXCLUDE (note) FROM orders")
