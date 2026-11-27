# The form komira does not have yet: a komira.pl frame writes its own Parquet
# file, as polars' sink_parquet does (komira-ai/komira#2368). It must fail
# with the line of probe_lazy_sink_parquet.error.txt.
from pathlib import Path

import komira.pl as pl

Path("orders.csv").write_text("order_id,amount\n1,120\n2,40\n")

pl.scan_csv("orders.csv").sink_parquet("orders.parquet")
