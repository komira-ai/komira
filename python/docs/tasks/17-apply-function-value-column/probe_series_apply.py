# The form komira does not have yet: apply any Python function to every
# value of a column, as pandas does with Series.apply (komira-ai/komira#2332).
# It must fail with the line of probe_series_apply.error.txt.
from pathlib import Path

import komira

Path("items.csv").write_text("name,price\nana,10.5\nbo,3.25\n")

df = komira.read_csv("items.csv")
df["price"].apply(lambda x: x * 2)
