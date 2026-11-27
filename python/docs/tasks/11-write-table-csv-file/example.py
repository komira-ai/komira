from pathlib import Path

import komira
import komira.pl as pl
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

# The CSV options DuckDB's COPY takes: a delimiter, no header line, a NULL text.
with komira.Session() as s:
    s.register_csv("sales", "sales.csv")
    s.sql(
        "COPY (SELECT id, region, amount FROM sales WHERE region <> 'east' ORDER BY id)"
        " TO 'out_semicolon.csv' (FORMAT csv, DELIMITER ';', HEADER false, NULL 'NA')"
    ).to_arrow()
print(Path("out_semicolon.csv").read_text(), end="")

# The pandas-shaped frame: run it, then write the Arrow table with pyarrow.
df = komira.read_csv("sales.csv")
totals = df.groupby("region", as_index=False)["qty"].sum().sort_values("region")
pacsv.write_csv(totals.materialize().to_arrow(), "totals.csv")
print(Path("totals.csv").read_text(), end="")

# The polars-shaped frame writes its own rows: sink_csv runs the plan in the engine.
lf = pl.scan_csv("sales.csv")
lf.filter(pl.col("region") != "east").select("id", "region", "amount").sort("id").sink_csv("sunk.csv")
print(Path("sunk.csv").read_text(), end="")
