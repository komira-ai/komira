# The form komira does not have yet: SQL PIVOT, which turns the values of
# a column into columns (komira-ai/komira#2399). It must fail
# with the line of probe_sql_pivot.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("region,product,amount\neast,pen,10\nwest,ink,5\n")

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.sql("SELECT * FROM sales PIVOT (sum(amount) FOR product IN ('pen', 'ink'))")
