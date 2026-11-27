# The form komira does not have yet: .str.split(expand=True), one column per
# piece. It must fail with the line of probe_split_expand.error.txt.
from pathlib import Path

import komira

Path("people.csv").write_text("id,full_name\n1,Ana Smith\n2,Bo Lee\n")

df = komira.read_csv("people.csv")
df["full_name"].str.split(" ", expand=True)
