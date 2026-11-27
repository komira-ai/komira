# The form komira does not have yet: pandas' to_numeric with
# errors="coerce", which makes a value that is not a number null
# (komira-ai/komira#2402). It must fail with the line of
# probe_to_numeric.error.txt.
from pathlib import Path

import komira

Path("readings.csv").write_text("sensor,count\na,12\nb,oops\n")

df = komira.read_csv("readings.csv")
df.assign(count=komira.to_numeric(df["count"], errors="coerce")).materialize()
