# The pandas spelling komira does not have: DataFrame.drop. Keep the columns
# you want with df[[...]] instead (see the page).
# It must fail with the line of probe_pandas_drop.error.txt.
from pathlib import Path

import komira

Path("orders.csv").write_text("order_id,customer,note\n1,Ana,gift\n")

df = komira.read_csv("orders.csv")
df.drop(columns=["note"])
