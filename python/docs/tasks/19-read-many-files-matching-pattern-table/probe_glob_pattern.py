# The form komira does not have yet: one name with a wildcard that reads
# every file it matches, here as DuckDB's read_csv('sales/sales_*.csv')
# (komira-ai/komira#2385). It must fail with the line of probe_glob_pattern.error.txt.
from pathlib import Path

import komira

Path("sales").mkdir()
for month, rows in {"jan": "1,2.5\n", "feb": "2,1.5\n"}.items():
    Path(f"sales/sales_{month}.csv").write_text("id,amt\n" + rows)

with komira.Session() as s:
    s.sql("SELECT count(*) FROM read_csv('sales/sales_*.csv')").to_arrow()
