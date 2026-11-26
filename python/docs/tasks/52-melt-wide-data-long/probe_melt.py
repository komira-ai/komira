# The form komira does not have yet: pandas' df.melt (komira-ai/komira#2400).
# It must fail with the line of probe_melt.error.txt.
from pathlib import Path

import komira

Path("scores.csv").write_text("name,q1,q2,q3\nAna,10,20,30\n")

df = komira.read_csv("scores.csv")
df.melt(id_vars=["name"], var_name="quarter", value_name="score")
