# The form komira does not have yet: the pandas-shaped pivot_table
# (komira-ai/komira#2400). It must fail with the line of
# probe_pivot_table.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("region,product,amount\neast,pen,10\nwest,ink,5\n")

df = komira.read_csv("sales.csv")
df.pivot_table(index="region", columns="product", values="amount", aggfunc="sum")
