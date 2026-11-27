# The form komira does not have yet: komira writes the file into the
# database itself, after ATTACH ... (TYPE sqlite) and INSERT INTO ... SELECT
# (komira-ai/komira#2335). It must fail with the line of
# probe_native_attach.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text("id,region,cents\n1,north,120\n2,south,340\n")

with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.sql("ATTACH 'sales.db' AS db (TYPE sqlite)")
    s.sql("INSERT INTO db.sales SELECT id, region, cents FROM sales WHERE cents > 0")
