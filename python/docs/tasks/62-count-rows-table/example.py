from pathlib import Path

import komira
import komira.pl as kpl

# An empty field reads as NULL.
Path("items.csv").write_text(
    "id,region,score\n"
    "1,east,9\n"
    "2,west,7\n"
    "3,east,\n"
    "4,north,5\n"
    "5,west,8\n"
)

# SQL: count(*) counts rows; count(column) counts the rows where it is not NULL.
with komira.Session() as s:
    s.register_csv("items", "items.csv")
    counts = s.sql("SELECT count(*) AS n, count(score) AS scored FROM items")
    print(counts.to_arrow().to_pylist())

# pandas-shaped: len(df) needs a query to run, so count with a "size" aggregate.
df = komira.read_csv("items.csv")
print(df.agg(n=("id", "size")).materialize().to_arrow().to_pylist())
print(df.groupby("region").size().materialize().to_arrow().to_pylist())

# polars-shaped: select(len()) is one row holding the count.
print(kpl.scan_csv("items.csv").select(kpl.len()).collect().to_arrow().to_pylist())
