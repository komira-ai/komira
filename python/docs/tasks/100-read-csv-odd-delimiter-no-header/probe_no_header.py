# The form komira does not have yet: a CSV with no header line, whose columns
# are named column0, column1, ... as DuckDB names them.
# It must fail with the line of probe_no_header.error.txt.
from pathlib import Path

import komira

Path("scores.csv").write_text("1,Ana,3\n2,Bo,5\n")

with komira.Session() as s:
    s.register_csv("scores", "scores.csv", header=False)
    s.sql("SELECT * FROM scores")
