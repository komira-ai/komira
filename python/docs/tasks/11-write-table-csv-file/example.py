from pathlib import Path

import komira
import pyarrow.csv as pacsv

Path("sales.csv").write_text("id,region,qty,amount\n1,north,2,2.5\n2,south,5,\n3,north,3,4.5\n4,east,1,1.0\n")

# SQL: COPY writes a query's result to a file and answers the row count.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    written = s.sql(
        "COPY (SELECT id, region, amount FROM sales WHERE region <> 'east' ORDER BY id)"
        " TO 'out.csv' (FORMAT csv, HEADER true)"
    ).to_arrow()
print("rows written:", written.column("Count")[0].as_py())
print(Path("out.csv").read_text(), end="")

# The pandas-shaped frame: run it, then write the Arrow table with pyarrow.
df = komira.read_csv("sales.csv")
totals = df.groupby("region", as_index=False)["qty"].sum().sort_values("region")
pacsv.write_csv(totals.materialize().to_arrow(), "totals.csv", pacsv.WriteOptions(quoting_style="needed"))
print(Path("totals.csv").read_text(), end="")
