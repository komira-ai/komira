# The form komira does not have yet: pandas' df.pivot (komira-ai/komira#2400).
# It must fail with the line of probe_pivot_method.error.txt.
from pathlib import Path

import komira

Path("scores.csv").write_text("name,quarter,score\nAna,q1,10\nAna,q2,20\n")

df = komira.read_csv("scores.csv")
df.pivot(index="name", columns="quarter", values="score")
