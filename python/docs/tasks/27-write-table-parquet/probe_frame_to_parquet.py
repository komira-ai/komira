# The form komira does not have yet: the frame writes its own Parquet file,
# as pandas' df.to_parquet(path) does (komira-ai/komira#2368). It must
# fail with the line of probe_frame_to_parquet.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("order_id,amount\n1,120\n2,40\n")

df = komira.read_csv("orders.csv")
df.to_parquet("orders.parquet")
