# The form komira does not have yet: the pandas-shaped frame writes itself,
# df.to_csv(path, index=False) (komira-ai/komira#2372).
# It must fail with the line of probe_frame_to_csv.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("id,region\n1,north\n2,south\n")

df = komira.read_csv("sales.csv")
df.to_csv("out.csv", index=False)
