# The form komira does not have yet: skip the lines above the header of a CSV,
# with read_csv's skip option as DuckDB spells it.
# It must fail with the line of probe_skip_lines.error.txt.
from pathlib import Path

import komira

Path("notes.csv").write_text("exported by the till\nid,name\n1,Ana\n2,Bo\n")

with komira.Session() as s:
    s.sql("SELECT * FROM read_csv('notes.csv', skip = 1)")
