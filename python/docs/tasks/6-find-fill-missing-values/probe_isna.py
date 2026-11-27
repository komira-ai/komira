# The form komira does not have yet: the pandas-shaped isna(), which marks the
# missing values of a frame (komira-ai/komira#2362).
# It must fail with the line of probe_isna.error.txt.
from pathlib import Path

import komira

Path("readings.csv").write_text("id,score\n1,12.5\n2,\n")
df = komira.read_csv("readings.csv")
print(df.isna().sum())
