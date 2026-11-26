from pathlib import Path

import komira
import komira.pl as pl

Path("people.csv").write_text("id,name,city\n1,Ana,Oslo\n2,Bo,Lima\n3,Cy,Oslo\n")

# SQL: the answer is read into an Arrow table, and to_pylist() makes one dict per row.
with komira.Session() as s:
    s.register_csv("people", "people.csv")
    table = s.sql("SELECT id, name FROM people ORDER BY id").to_arrow()
    print(table.to_pylist())

    # The other shape: one list per column.
    print(table.to_pydict())

# pandas-shaped: materialize() runs the frame, then the same call.
df = komira.read_csv("people.csv")
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: collect() runs the frame.
lf = pl.scan_csv("people.csv").sort("id")
print(lf.collect().to_arrow().to_pylist())
