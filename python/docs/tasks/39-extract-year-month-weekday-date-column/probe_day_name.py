# The form komira does not have yet: the weekday as a name, with .dt.day_name().
# It must fail with the line of probe_day_name.error.txt.
from pathlib import Path

import komira

Path("days.csv").write_text("id,d\n1,2026-10-01\n")

df = komira.read_csv("days.csv")
df["d"].dt.day_name()
