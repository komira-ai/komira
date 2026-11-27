# The form komira does not have yet: apply a Python function to every value
# of a column, as polars does with Expr.map_elements (komira-ai/komira#2384).
# It must fail with the line of probe_polars_map_elements.error.txt.
from pathlib import Path

import komira.pl as pl

Path("items.csv").write_text("name,price\nana,10.5\nbo,3.25\n")

lf = pl.scan_csv("items.csv")
lf.with_columns(pl.col("price").map_elements(lambda x: x * 2, return_dtype=pl.Float64))
