from pathlib import Path

import komira
import komira.pl as pl
import pyarrow as pa
import pyarrow.parquet as pq

# One file per month in a folder, all with the same columns. A file that
# does not match the pattern sits beside them. The same files also go in a
# folder per month named month=<month>, the layout Hive and Spark write.
Path("sales").mkdir()
months = {"jan": [(1, "a", 2.5), (2, "b", 3.5)], "feb": [(3, "c", 1.5)], "mar": [(4, "d", 0.5), (5, "e", 4.5)]}
for month, rows in months.items():
    ids, names, amts = zip(*rows)
    table = pa.table({"id": list(ids), "name": list(names), "amt": list(amts)})
    pq.write_table(table, f"sales/sales_{month}.parquet")
    Path(f"by_month/month={month}").mkdir(parents=True)
    pq.write_table(table, f"by_month/month={month}/data.parquet")
    csv = "id,name,amt\n" + "".join(f"{i},{n},{a}\n" for i, n, a in rows)
    Path(f"sales/sales_{month}.csv").write_text(csv)
pq.write_table(pa.table({"id": [9], "name": ["skip"], "amt": [9.0]}), "sales/notes.parquet")

# Parquet and SQL: the pattern goes in the path, and the files read as one table.
with komira.Session() as s:
    s.register_parquet("sales", "sales/sales_*.parquet")
    print(s.sql("SELECT * FROM sales ORDER BY id").to_arrow().to_pylist())
    both = s.sql("SELECT count(*) AS n, sum(amt) AS total FROM read_parquet('sales/sales_*.parquet')")
    print(both.to_arrow().to_pylist())

# pandas-shaped and polars-shaped: the pattern in the path reads every file
# it matches as one frame.
df = komira.read_parquet("sales/sales_*.parquet")
print(df.sort_values("id").materialize().to_arrow().to_pylist())
lf = pl.scan_parquet("sales/sales_*.parquet")
print(lf.sort("id").collect().to_arrow().to_pylist())

# A folder of key=value folders reads as one frame, the key a column.
print(komira.read_parquet("by_month").sort_values("id").materialize().to_arrow().to_pylist())
print(pl.scan_parquet("by_month").sort("id").collect().to_arrow().to_pylist())

# CSV has no pattern yet: Python matches the files, komira reads each one.
files = sorted(Path("sales").glob("sales_*.csv"))
print(len(files), "csv files")

# SQL: register each file, then stack them with UNION ALL.
with komira.Session() as s:
    for i, f in enumerate(files):
        s.register_csv(f"part{i}", str(f))
    stacked = " UNION ALL ".join(f"SELECT * FROM part{i}" for i in range(len(files)))
    print(s.sql(f"SELECT * FROM ({stacked}) ORDER BY id").to_arrow().to_pylist())

# pandas-shaped: read each file, then concat.
df = komira.concat([komira.read_csv(str(f)) for f in files])
print(df.sort_values("id").materialize().to_arrow().to_pylist())

# polars-shaped: scan each file lazily, then concat.
lf = pl.concat([pl.scan_csv(str(f)) for f in files])
print(lf.sort("id").collect().to_arrow().to_pylist())
