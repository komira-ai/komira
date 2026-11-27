# The form most people write, which komira does not run yet: filter the
# row number with rn <= 2. It must fail with the line of
# probe_rn_at_most.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("region,rep,amount\neast,Ana,120\neast,Bo,80\nwest,Ed,90\n")

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.sql(
        "SELECT region, rep, amount FROM ("
        " SELECT region, rep, amount,"
        " ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn"
        " FROM sales) ranked WHERE rn <= 2 ORDER BY region, rn"
    )
