# The form komira does not have yet: the pandas-shaped DataFrame.replace,
# which turns listed placeholder values into nulls in one call
# (komira-ai/komira#2401). It must fail with the line of
# probe_replace.error.txt.
from pathlib import Path

import komira

Path("contacts.csv").write_text("name,city\nAna,Oslo\nBo,N/A\n")

df = komira.read_csv("contacts.csv")
df.replace(["N/A", "n/a", "-"], None).materialize()
