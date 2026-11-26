# The pandas form komira does not have yet: komira.to_datetime(series, unit="s")
# turns Unix seconds into a datetime column (komira-ai/komira#2344).
# It must fail with the line of probe_to_datetime.error.txt.
from pathlib import Path

import komira

Path("events.csv").write_text("unix_s\n1788220800\n")

df = komira.read_csv("events.csv")
df["ts"] = komira.to_datetime(df["unix_s"], unit="s")
