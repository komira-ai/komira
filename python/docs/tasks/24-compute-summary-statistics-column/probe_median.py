# The form komira does not have yet: the median of a column, here on the
# pandas-shaped frame (komira-ai/komira#2367). It must fail with the line of
# probe_median.error.txt.
from pathlib import Path

import komira

Path("prices.csv").write_text("item,price\na,10\nb,20\nc,20\nd,30\ne,50\nf,\n")

df = komira.read_csv("prices.csv")
print(df[["price"]].median().materialize().to_arrow().to_pylist())
