# The form komira does not have yet: DuckDB's PIVOT, which spreads a column
# into new columns in one clause (komira-ai/komira#2399). pandas'
# df.pivot is the same missing operation. It must fail with the line of
# probe_pivot.error.txt.
from pathlib import Path

import komira

Path("scores.csv").write_text("name,quarter,score\nAna,q1,10\nAna,q2,20\n")

with komira.Session() as s:
    s.register_csv("scores", "scores.csv")
    s.sql("SELECT * FROM scores PIVOT (sum(score) FOR quarter IN ('q1', 'q2'))")
