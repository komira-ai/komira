# The form komira does not have yet: the interquartile-range rule, with the
# quartiles of a column from Series.quantile (komira-ai/komira#2367).
# It must fail with the line of probe_quantile.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("id,total\n1,10\n2,12\n3,11\n4,95\n")

df = komira.read_csv("orders.csv")
q1, q3 = df["total"].quantile(0.25), df["total"].quantile(0.75)
iqr = q3 - q1
df[(df["total"] < q1 - 1.5 * iqr) | (df["total"] > q3 + 1.5 * iqr)].materialize()
