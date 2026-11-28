from pathlib import Path

import komira
import komira.pl as pl
import pyarrow as pa
import pyarrow.parquet as pq

# One file per month in a folder, all with the same columns. A file that
# does not match the pattern sits beside them.
Path("sales").mkdir()
months = {"jan": [(1, "a", 2.5), (2, "b", 3.5)], "feb": [(3, "c", 1.5)], "mar": [(4, "d", 0.5), (5, "e", 4.5)]}
for month, rows in months.items():
    ids, names, amts = zip(*rows)
    table = pa.table({"id": list(ids), "name": list(names), "amt": list(amts)})
    pq.write_table(table, f"sales/sales_{month}.parquet")
    csv = "id,name,amt\n" + "".join(f"{i},{n},{a}\n" for i, n, a in rows)
    Path(f"sales/sales_{month}.csv").write_text(csv)
    lines = "".join(f'{{"id": {i}, "name": "{n}", "amt": {a}}}\n' for i, n, a in rows)
    Path(f"sales/sales_{month}.jsonl").write_text(lines)
pq.write_table(pa.table({"id": [9], "name": ["skip"], "amt": [9.0]}), "sales/notes.parquet")
Path("sales/notes.csv").write_text("note\nskip\n")

# The pattern goes in the path, for Parquet, CSV and JSON Lines alike, and the
# files it matches read as one table.
with komira.Session() as s:
    s.register_parquet("sales", "sales/sales_*.parquet")
    print(s.sql("SELECT * FROM sales ORDER BY id").to_arrow().to_pylist())
    both = s.sql("SELECT count(*) AS n, sum(amt) AS total FROM read_parquet('sales/sales_*.parquet')")
    print(both.to_arrow().to_pylist())

    s.register_csv("sales_csv", "sales/sales_*.csv")
    print(s.sql("SELECT * FROM sales_csv ORDER BY id").to_arrow().to_pylist())
    csv_sql = s.sql("SELECT count(*) AS n, sum(amt) AS total FROM read_csv('sales/sales_*.csv')")
    print(csv_sql.to_arrow().to_pylist())
    print(s.sql("SELECT max(id) AS last FROM 'sales/sales_*.csv' WHERE amt > 1").to_arrow().to_pylist())

    s.register_json("sales_json", "sales/sales_*.jsonl")
    print(s.sql("SELECT name FROM sales_json ORDER BY id").to_arrow().to_pylist())

# The pandas- and polars-shaped readers take one file: match the files with
# pathlib, then concat.
files = sorted(Path("sales").glob("sales_*.csv"))
df = komira.concat([komira.read_csv(str(f)) for f in files])
print(df.sort_values("id").materialize().to_arrow().to_pylist())

lf = pl.concat([pl.scan_csv(str(f)) for f in files])
print(lf.sort("id").collect().to_arrow().to_pylist())
