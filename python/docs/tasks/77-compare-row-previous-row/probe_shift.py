# The pandas form: df.shift(1) for the previous row, df.diff() for the change
# (komira-ai/komira#2387).
# It must fail with the line of probe_shift.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("t,sales\n1,10\n2,13\n")

df = komira.read_csv("sales.csv")
df.shift(1)
