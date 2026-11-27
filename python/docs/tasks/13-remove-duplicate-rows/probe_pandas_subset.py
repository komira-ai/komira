# The form komira does not have yet: df.drop_duplicates(subset=[...]) keeps one
# whole row for each value of the named columns (komira-ai/komira#2378).
# It must fail with the line of probe_pandas_subset.error.txt.
from pathlib import Path

import komira

Path("people.csv").write_text("id,name,city\n1,Ana,Oslo\n2,Bo,Rome\n4,Ana,Lima\n")

df = komira.read_csv("people.csv")
print(df.drop_duplicates(subset=["name"]).sort_values("name").materialize().to_arrow().to_pylist())
