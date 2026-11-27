# The form komira does not have yet: a crosstab function that counts the
# pairs of two columns in one call (komira-ai/komira#2400). It
# must fail with the line of probe_crosstab.error.txt.
from pathlib import Path

import komira

Path("tickets.csv").write_text("team,priority\nweb,high\napi,low\n")

df = komira.read_csv("tickets.csv")
komira.crosstab(df["team"], df["priority"])
