# The form komira does not have yet: komira closes the current version of a
# changed row in the history table itself, with UPDATE (and adds the new
# version with INSERT INTO ... SELECT), komira-ai/komira#2335. It must fail
# with the line of probe_native_update.error.txt.
from pathlib import Path

import komira

Path("snapshots.csv").write_text("customer,tier,day_key\n1,1,20260901\n1,2,20260903\n")

with komira.Session() as s:
    s.register_csv("snapshots", "snapshots.csv")
    s.sql("UPDATE tier_history SET valid_to = 20260903 WHERE customer = 1 AND valid_to IS NULL")
