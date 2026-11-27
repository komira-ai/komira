# The form komira does not have yet: the polars-shaped frame writes itself,
# lf.sink_csv(path) (komira-ai/komira#2372).
# It must fail with the line of probe_lazyframe_sink_csv.error.txt.
from pathlib import Path

import komira.pl as pl

Path("sales.csv").write_text("id,region\n1,north\n2,south\n")

pl.scan_csv("sales.csv").sink_csv("out.csv")
