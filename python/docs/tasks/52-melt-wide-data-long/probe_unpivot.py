# The form komira does not have yet: DuckDB's UNPIVOT, which melts the
# columns in one clause (komira-ai/komira#2399). pandas' df.melt is the
# same missing operation. It must fail with the line of probe_unpivot.error.txt.
from pathlib import Path

import komira

Path("scores.csv").write_text("name,q1,q2,q3\nAna,10,20,30\n")

with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    s.sql("SELECT * FROM scores UNPIVOT (score FOR quarter IN (q1, q2, q3))")
