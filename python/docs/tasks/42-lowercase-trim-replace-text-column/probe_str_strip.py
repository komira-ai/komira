# The form komira does not have yet: .str.strip() on the pandas-shaped frame.
# It must fail with the line of probe_str_strip.error.txt.
from pathlib import Path

import komira

Path("people.csv").write_text("id,name\n1,  Ana \n")

df = komira.read_csv("people.csv")
df["name"] = df["name"].str.strip()
