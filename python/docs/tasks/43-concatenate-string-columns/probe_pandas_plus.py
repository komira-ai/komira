# The form komira does not have yet: adding string columns with + on the
# pandas-shaped frame. It must fail with the line of probe_pandas_plus.error.txt.
from pathlib import Path

import komira

Path("people.csv").write_text("id,first,last\n1,Ana,Diaz\n")

df = komira.read_csv("people.csv")
df["name"] = df["first"] + df["last"]
print(df.materialize().to_arrow().to_pylist())
