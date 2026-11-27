# The form komira does not have yet: pandas' DataFrame.resample on a date
# column (komira-ai/komira#2392). It must fail with the line of
# probe_pandas_resample.error.txt.
from pathlib import Path

import komira

Path("sales.csv").write_text(
    "sold_on,amount\n"
    "2026-10-01,10.5\n"
    "2026-10-02,20.0\n"
    "2026-11-02,6.5\n"
)

df = komira.read_csv("sales.csv")
monthly = df.resample("MS", on="sold_on")["amount"].sum()
print(monthly.materialize().to_arrow().to_pylist())
